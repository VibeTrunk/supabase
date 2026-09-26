-- Midweek Madness, migration D: the payouts (BUILD_SPEC §44.7, §44.14;
-- Part L #26; ADR-089, ADR-095, ADR-096).
--
-- Every match won pays coins, rising by round, so a champion collects exactly
-- MIDWEEK_CHAMPION_TOTAL (250); a bye pays as a round-1 win. The worker's
-- complete step pays, in the same transaction that publishes the seed and
-- marks the week complete, after the final is revealed and never before
-- (§44.7). Coins come from the stored bracket, kut.midweek_matches, and the
-- engine's kut._mm_round_payouts, so a payment can never disagree with what
-- members saw.
--
--   1. Constraint widening             -- ledger reason 'midweek_win',
--                                         notification type 'midweek_result'.
--   2. kut.midweek_rewards             -- the guard table: one row per
--                                         (tournament, round, member), the
--                                         kut.bibs_rewards pattern.
--   3. Part L #26 guard                -- a reward pays a stored win at its
--                                         round's amount, once, while the week
--                                         is being completed; one tournament
--                                         pays a member at most 250.
--   4. kut._mm_pay_tournament          -- the payment: guard row, wallet,
--                                         ledger, balance (grant_bibs_reward's
--                                         sequence), then one inbox message per
--                                         member paid.
--   5. kut._mm_complete_tournament     -- re-created to pay before the status
--                                         flips. Its contract is unchanged.
--   6. kut.my_midweek_rewards          -- the caller's own rewards (HANDOFF
--                                         "Your coins"), a gated projection.
--
-- Void stays as it was: kut.admin_void_midweek refuses a complete week, and a
-- week is complete exactly when it has been paid, so a paid week cannot be
-- voided. A void before the final pays nobody, because only a simulated week
-- is ever completed.
--
-- Tier: data-changing (docs/OPERATIONS.md): it changes what the ledger and
-- wallets accept and adds a coin faucet. The migration itself writes no row and
-- moves no coin; the worker pays only once a tournament exists, which needs the
-- switch, off on hosted.
--
-- Rollback (the switch off, and no tournament simulated or completed since):
--   re-create kut._mm_complete_tournament from 20261005000000_midweek_engine.sql;
--   drop view kut.my_midweek_rewards;
--   drop function kut._mm_pay_tournament(uuid);
--   drop trigger midweek_rewards_guard on kut.midweek_rewards;
--   drop function kut._mm_guard_reward();
--   drop table kut.midweek_rewards;
--   re-create both constraints with the lists from 20260930000000_injury_protection.sql
--     (only once no ledger row has reason 'midweek_win' and no notification
--     has type 'midweek_result').

-- 1. Constraint widening -------------------------------------------------------
-- Lists copied from 20260930000000_injury_protection.sql section 2, the latest
-- to change either, each with one value appended.

do $$ declare v_name text; begin
  select conname into v_name from pg_constraint
  where conrelid = 'kut.wallet_ledger'::regclass and contype = 'c'
    and pg_get_constraintdef(oid) ilike '%reason%' and pg_get_constraintdef(oid) ilike '%injury_stipend%';
  if v_name is null then raise exception 'wallet ledger reason constraint not found'; end if;
  execute format('alter table kut.wallet_ledger drop constraint %I', v_name);
end $$;
alter table kut.wallet_ledger add constraint wallet_ledger_reason_check check (reason in (
  'starter','attendance_reward','pack_purchase','discard','market_sale','market_buy','market_tax','admin_correction','admin_grant','admin_reset','bibs_bonus','trade_escrow','trade_unescrow','trade_sale','admin_self_grant','session_report_reward','injury_stipend','midweek_win'
));

do $$ declare v_name text; begin
  select conname into v_name from pg_constraint
  where conrelid = 'kut.user_notifications'::regclass and contype = 'c'
    and pg_get_constraintdef(oid) ilike '%event_type%' and pg_get_constraintdef(oid) ilike '%injury_check_in%';
  if v_name is null then raise exception 'notification event_type constraint not found'; end if;
  execute format('alter table kut.user_notifications drop constraint %I', v_name);
end $$;
alter table kut.user_notifications add constraint user_notifications_event_type_check check (event_type in (
  'market_sale','market_purchase','attendance_reward','pack_opened','admin_notice','bibs_bonus','trade_offer','trade_response','session_report','session_results','report_correction','kudos_awarded','injury_check_in','midweek_result'
));

-- 2. The guard table -------------------------------------------------------------
-- The primary key is the idempotency guard (the kut.bibs_rewards pattern): a
-- win is paid at most once per (tournament, round, member). The ledger row's
-- idempotency key, 'midweek:<tournament>:<round>:<member>', guards it twice.
-- The ledger foreign key is deferred because the guard row is written first.
-- Money-bearing rows restrict deletes of what they point at, as
-- kut.attendance_rewards and kut.bibs_rewards do.
create table kut.midweek_rewards (
  tournament_id uuid not null references kut.midweek_tournaments(id) on delete restrict,
  round_no smallint not null check (round_no between 1 and 10),
  user_id uuid not null references kut.profiles(id) on delete restrict,
  -- The stored pairing the member won; a bye is a round-1 win.
  match_id uuid not null references kut.midweek_matches(id) on delete restrict,
  bye boolean not null,
  amount bigint not null check (amount > 0),
  ledger_id uuid not null references kut.wallet_ledger(id) on delete restrict deferrable initially deferred,
  created_at timestamptz not null default now(),
  primary key (tournament_id, round_no, user_id),
  unique (match_id),
  check (not bye or round_no = 1)
);
create index midweek_rewards_user_idx on kut.midweek_rewards (user_id, created_at desc);

alter table kut.midweek_rewards enable row level security;
revoke all on kut.midweek_rewards from public, anon, authenticated;
grant select on kut.midweek_rewards to service_role;

comment on table kut.midweek_rewards is
  'ADR-096, Part L #26: one row per Midweek Madness win paid, (tournament, round, member) at most once. Members read their own through kut.my_midweek_rewards.';

-- 3. Part L #26: a win pays once, at its round's amount -------------------------
-- A reward is written only by the complete step: while its tournament is still
-- simulated and its final is revealed. It must pay a stored win (the member
-- won that pairing in that round) at exactly that round's amount, and a
-- member's rewards for one tournament never exceed the champion's total. A
-- paid reward never changes. Deleting a reward row cannot make the win pay
-- again, because a week is paid only while it is being completed, once.
create function kut._mm_guard_reward()
returns trigger language plpgsql set search_path = kut, pg_catalog as $$
declare
  v_tournament kut.midweek_tournaments%rowtype;
  v_match kut.midweek_matches%rowtype;
  v_paid bigint;
begin
  if tg_op = 'UPDATE' then
    raise exception 'a paid Midweek reward is final' using errcode = '55000';
  end if;
  select * into v_tournament from kut.midweek_tournaments where id = new.tournament_id;
  if v_tournament.status is distinct from 'simulated' or v_tournament.final_reveal_at > now() then
    raise exception 'Midweek rewards are paid once, when the final is revealed' using errcode = '55000';
  end if;
  select * into v_match from kut.midweek_matches where id = new.match_id;
  if not found or v_match.tournament_id <> new.tournament_id or v_match.round <> new.round_no
    or v_match.winner_user_id <> new.user_id or v_match.bye <> new.bye then
    raise exception 'a Midweek reward pays a win in the stored bracket' using errcode = '23514';
  end if;
  if new.amount <> (kut._mm_round_payouts(v_tournament.rounds))[new.round_no] then
    raise exception 'a Midweek reward pays its round''s amount' using errcode = '23514';
  end if;
  -- Other rounds only: a second row for the same round is the primary key's
  -- to refuse, so ON CONFLICT DO NOTHING still does nothing.
  select coalesce(sum(amount), 0) into v_paid
  from kut.midweek_rewards
  where tournament_id = new.tournament_id and user_id = new.user_id and round_no <> new.round_no;
  if v_paid + new.amount > (kut._mm_config()->>'championTotal')::bigint then
    raise exception 'one Midweek tournament pays a member at most %', kut._mm_config()->>'championTotal'
      using errcode = '23514';
  end if;
  return new;
end $$;

create trigger midweek_rewards_guard before insert or update on kut.midweek_rewards
  for each row execute function kut._mm_guard_reward();

revoke all on function kut._mm_guard_reward() from public, anon, authenticated;

-- 4. The payment -------------------------------------------------------------------
-- Pays every win in the stored bracket of a tournament the caller has locked
-- for completion: each round's winners, byes as round-1 wins, at
-- _mm_round_payouts(rounds). Per win, grant_bibs_reward's sequence: guard row,
-- wallet, ledger row, balance. A member disabled since the lock is not paid,
-- as grant_bibs_reward skips one. Then one 'midweek_result' message per member
-- paid, deduplicated by reference. Returns the number of wins paid.
create function kut._mm_pay_tournament(p_tournament_id uuid)
returns integer language plpgsql security definer set search_path = kut, pg_catalog as $$
declare
  v_tournament kut.midweek_tournaments%rowtype;
  v_pays integer[];
  v_win record;
  v_ledger_id uuid;
  v_paid integer := 0;
  v_champion text;
  v_night text;
begin
  select * into v_tournament from kut.midweek_tournaments where id = p_tournament_id;
  if v_tournament.status is distinct from 'simulated' then return 0; end if;
  v_pays := kut._mm_round_payouts(v_tournament.rounds);

  for v_win in
    select played.id as match_id, played.round, played.bye, played.winner_user_id as user_id
    from kut.midweek_matches played
    join kut.profiles winner on winner.id = played.winner_user_id
    where played.tournament_id = p_tournament_id and not winner.is_disabled
    order by played.round, played.pairing
  loop
    v_ledger_id := gen_random_uuid();
    insert into kut.midweek_rewards (tournament_id, round_no, user_id, match_id, bye, amount, ledger_id)
    values (p_tournament_id, v_win.round, v_win.user_id, v_win.match_id, v_win.bye, v_pays[v_win.round], v_ledger_id)
    on conflict (tournament_id, round_no, user_id) do nothing;
    if not found then continue; end if;

    insert into kut.wallets (user_id, balance) values (v_win.user_id, 0)
    on conflict (user_id) do nothing;
    insert into kut.wallet_ledger (id, user_id, amount, reason, reference_type, reference_id, idempotency_key)
    values (
      v_ledger_id, v_win.user_id, v_pays[v_win.round], 'midweek_win', 'midweek_tournament', p_tournament_id,
      'midweek:' || p_tournament_id::text || ':' || v_win.round::text || ':' || v_win.user_id::text
    );
    update kut.wallets set balance = balance + v_pays[v_win.round], updated_at = now()
    where user_id = v_win.user_id;
    v_paid := v_paid + 1;
  end loop;

  select profile.display_name into v_champion
  from kut.midweek_matches final
  join kut.profiles profile on profile.id = final.winner_user_id
  where final.tournament_id = p_tournament_id and final.round = v_tournament.rounds;
  -- The night the week was due to be played: its scheduled Wednesday.
  v_night := to_char(kut._mm_lock_at(v_tournament.week_start) at time zone 'Europe/Amsterdam', 'Dy FMDD Mon');

  -- How far each member paid got: the champion won the final; anyone else
  -- went out in the round after their last win.
  insert into kut.user_notifications (user_id, event_type, title, body, reference_type, reference_id)
  select paid.user_id, 'midweek_result', 'Midweek Madness',
    case
      when paid.last_round = v_tournament.rounds then
        format('You won Midweek Madness on %s: %s KUT Coins over the night.', v_night, paid.total)
      when v_tournament.rounds - paid.last_round <= 3 then
        format('You reached the %s on %s: +%s KUT Coins. %s won it.',
          (array['final', 'semi-finals', 'quarter-finals'])[v_tournament.rounds - paid.last_round],
          v_night, paid.total, v_champion)
      else
        format('You went out in round %s on %s: +%s KUT Coins. %s won it.',
          paid.last_round + 1, v_night, paid.total, v_champion)
    end,
    'midweek_tournament', p_tournament_id
  from (
    select user_id, sum(amount) as total, max(round_no) as last_round
    from kut.midweek_rewards where tournament_id = p_tournament_id
    group by user_id
  ) paid
  on conflict (user_id, event_type, reference_type, reference_id)
    where reference_type is not null and reference_id is not null do nothing;

  return v_paid;
end $$;
revoke all on function kut._mm_pay_tournament(uuid) from public, anon, authenticated;

-- 5. The complete step pays ---------------------------------------------------------
-- Identical to 20261005000000_midweek_engine.sql section 4 except that it pays
-- (kut._mm_pay_tournament) before the status flips, in the same transaction:
-- a week is complete exactly when it has been paid. The row lock taken here
-- serialises concurrent worker calls, and the one that finds the week no
-- longer simulated returns 'not_due'.
create or replace function kut._mm_complete_tournament(p_tournament_id uuid)
returns text language plpgsql security definer set search_path = kut, pg_catalog as $$
declare v_tournament kut.midweek_tournaments%rowtype;
begin
  select * into v_tournament from kut.midweek_tournaments where id = p_tournament_id for update;
  if not found or v_tournament.status <> 'simulated' or v_tournament.final_reveal_at > now() then
    return 'not_due';
  end if;
  perform kut._mm_pay_tournament(p_tournament_id);
  update kut.midweek_tournaments
  set status = 'complete', updated_at = now(),
    seed = (select seed from kut.midweek_tournament_secrets where tournament_id = p_tournament_id)
  where id = p_tournament_id;
  return 'complete';
end $$;
revoke all on function kut._mm_complete_tournament(uuid) from public, anon, authenticated;

-- 6. The member's own rewards ---------------------------------------------------------
-- Every Midweek win the caller was paid for (HANDOFF "Your coins"), one row per
-- round, with the pairing for the report link. A definer view gated on
-- kut.is_active_member() (ADR-079), as kut.my_midweek_squad.
create view kut.my_midweek_rewards
with (security_invoker = false, security_barrier = true)
as
select
  reward.tournament_id,
  tournament.week_start,
  reward.round_no,
  reward.match_id,
  reward.bye,
  reward.amount,
  reward.created_at as paid_at
from kut.midweek_rewards reward
join kut.midweek_tournaments tournament on tournament.id = reward.tournament_id
where reward.user_id = auth.uid()
  and kut.is_active_member();

comment on view kut.my_midweek_rewards is
  'ADR-096: the caller''s own Midweek Madness rewards, one row per win paid (a bye is a round-1 win). Gated on kut.is_active_member() (ADR-079).';
revoke all on kut.my_midweek_rewards from public, anon;
grant select on kut.my_midweek_rewards to authenticated, service_role;
