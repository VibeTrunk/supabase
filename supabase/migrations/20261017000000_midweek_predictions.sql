-- Midweek Madness 2.0, D: predictions for members who are out (BUILD_SPEC §44.7,
-- §44.9, §44.14; Part L #28; ADR-118, amending ADR-096; owner decision Q2,
-- 2026-10-03).
--
-- Once a member's own match has ended in defeat, they may pick the winner of
-- each later match before its kick-off, as soon as both matches that feed it
-- have ended. A correct pick pays coins at the payout: 30 split over the
-- matches a round-1 loser could predict, so `kut._mm_prediction_coins(rounds)`
-- is 2 a pick with 17-32 entrants, 4 with 9-16, 10 with 5-8 and 30 with 4,
-- and nobody takes more than about 30 a night from predictions. No table: a
-- weekly line in the result message.
--
--   1. Constraint widening               -- ledger reason 'midweek_prediction'.
--   2. kut._mm_prediction_coins          -- coins per correct pick, the twin of
--                                           predictionCoins in
--                                           src/game/midweek/rewards.ts.
--   3. kut.midweek_predictions           -- one pick per (match, member), with
--                                           the Part L #28 guard: only a member
--                                           already out, only before the
--                                           match's kick-off, only once both
--                                           its feeders have ended, and only
--                                           one of its two managers.
--   4. kut.save_midweek_prediction       -- the member's call: save, change or
--                                           clear a pick.
--   5. kut.midweek_prediction_rewards    -- the guard table: one payment per
--                                           (week, member), at exactly the
--                                           correct picks' worth.
--   6. kut._mm_pay_tournament            -- re-created. Wins are paid exactly as
--                                           before (Part L #26 untouched); then
--                                           correct picks; the result message
--                                           gains one sentence for a member who
--                                           predicted.
--   7. Views                             -- the caller's own picks and rewards,
--                                           and each match's split from its
--                                           kick-off.
--
-- Nothing that gives a result away early: the save refuses a match until both
-- its feeders have ended, before it checks the pick against the stored
-- pairing, so a refusal never says who won a match still in play. A member's
-- picks are their own; others see only how the club split, from kick-off.
--
-- Deploy ordering: no page reads any of this yet (the pages follow a Claude
-- Design mock), so Vercel deploying before the push changes nothing, and with
-- no page nobody can predict, so nothing pays until the pages ship.
--
-- Tier: data-changing (docs/OPERATIONS.md): it widens what the ledger accepts,
-- adds a coin faucet and changes what the worker writes when it pays a week.
-- Fresh cold-verified backup before the push.
--
-- Rollback (no prediction saved yet, so nothing paid):
--   re-create kut._mm_pay_tournament from
--     20261013000000_midweek_result_for_everyone.sql (create or replace works);
--   drop view kut.midweek_prediction_splits_public, kut.my_midweek_prediction_rewards,
--     kut.my_midweek_predictions;
--   drop table kut.midweek_prediction_rewards, kut.midweek_predictions;
--   drop function kut.save_midweek_prediction(uuid, integer, integer, uuid),
--     kut._mm_guard_prediction(), kut._mm_guard_prediction_reward(),
--     kut._mm_prediction_coins(integer);
--   re-create the ledger constraint with the list from
--     20261006000000_midweek_payouts.sql section 1 (only once no ledger row
--     has reason 'midweek_prediction').

-- 1. Constraint widening -------------------------------------------------------------
-- The list from 20261006000000_midweek_payouts.sql section 1, the latest to
-- change it, with one value appended.
do $$ declare v_name text; begin
  select conname into v_name from pg_constraint
  where conrelid = 'kut.wallet_ledger'::regclass and contype = 'c'
    and pg_get_constraintdef(oid) ilike '%reason%' and pg_get_constraintdef(oid) ilike '%midweek_win%';
  if v_name is null then raise exception 'wallet ledger reason constraint not found'; end if;
  execute format('alter table kut.wallet_ledger drop constraint %I', v_name);
end $$;
alter table kut.wallet_ledger add constraint wallet_ledger_reason_check check (reason in (
  'starter','attendance_reward','pack_purchase','discard','market_sale','market_buy','market_tax','admin_correction','admin_grant','admin_reset','bibs_bonus','trade_escrow','trade_unescrow','trade_sale','admin_self_grant','session_report_reward','injury_stipend','midweek_win','midweek_prediction'
));

-- 2. Coins per correct pick ----------------------------------------------------------
-- 30 split over the matches after round 1, which a member out in round 1 can
-- predict: 2^(rounds - 1) - 1 of them. Integer division, so the most a night
-- pays stays at or under 30.
create function kut._mm_prediction_coins(p_rounds integer)
returns integer language sql immutable set search_path = kut, pg_catalog as $$
  select case when p_rounds is null or p_rounds < 2 then 0
    else 30 / ((1 << (p_rounds - 1)) - 1) end
$$;
revoke all on function kut._mm_prediction_coins(integer) from public, anon, authenticated;

-- 3. The picks -------------------------------------------------------------------------
create table kut.midweek_predictions (
  match_id uuid not null references kut.midweek_matches(id) on delete cascade,
  user_id uuid not null references kut.profiles(id) on delete cascade,
  tournament_id uuid not null references kut.midweek_tournaments(id) on delete cascade,
  predicted_user_id uuid not null references kut.profiles(id) on delete cascade,
  saved_at timestamptz not null default now(),
  primary key (match_id, user_id)
);
create index midweek_predictions_member_idx on kut.midweek_predictions (tournament_id, user_id);

alter table kut.midweek_predictions enable row level security;
revoke all on kut.midweek_predictions from public, anon, authenticated;
grant select on kut.midweek_predictions to service_role;

comment on table kut.midweek_predictions is
  'ADR-118, Part L #28: a member who is out picks the winner of a later match before its kick-off. Members read their own through kut.my_midweek_predictions.';

-- Part L #28, the picks: whoever writes the row, it must be a pick a member
-- out of the week could make before the match kicked off. Checked in an order
-- that never gives a result away: the member's own defeat (theirs to know),
-- the match and its kick-off (public), both feeders ended (public), and only
-- then the pick against the stored pairing, which by then is public too.
create function kut._mm_guard_prediction()
returns trigger language plpgsql security definer set search_path = kut, pg_catalog as $$
declare
  v_match kut.midweek_matches%rowtype;
  v_status text;
  v_open integer;
begin
  if tg_op = 'DELETE' then
    select * into v_match from kut.midweek_matches where id = old.match_id;
    -- A cascade from a deleted match or week passes; a member clears a pick
    -- only before kick-off.
    if found and v_match.reveal_at <= now() then
      raise exception 'predictions close at kick-off' using errcode = 'P0001';
    end if;
    return old;
  end if;
  if tg_op = 'UPDATE' and (new.match_id, new.user_id, new.tournament_id)
    is distinct from (old.match_id, old.user_id, old.tournament_id) then
    raise exception 'a prediction keeps its match and member' using errcode = '55000';
  end if;

  select status into v_status from kut.midweek_tournaments where id = new.tournament_id;
  if v_status is distinct from 'simulated' then
    raise exception 'predictions are open only while a week is being played' using errcode = 'P0001';
  end if;
  if not exists (
    select 1 from kut.midweek_matches lost
    where lost.tournament_id = new.tournament_id and not lost.bye
      and new.user_id in (lost.side_0_user_id, lost.side_1_user_id)
      and lost.winner_user_id <> new.user_id
      and lost.ends_at <= now()
  ) then
    raise exception 'predictions open once you are out' using errcode = 'P0001';
  end if;

  select * into v_match from kut.midweek_matches where id = new.match_id;
  if not found or v_match.tournament_id <> new.tournament_id or v_match.bye then
    raise exception 'no such match to predict' using errcode = 'P0002';
  end if;
  if v_match.reveal_at <= now() then
    raise exception 'predictions close at kick-off' using errcode = 'P0001';
  end if;
  -- Both matches that feed this one must have ended; round 1 has none, and a
  -- member out has played round 1, which kicks off for everyone at once.
  select count(*) into v_open
  from kut.midweek_matches feeder
  where feeder.tournament_id = new.tournament_id
    and feeder.round = v_match.round - 1
    and feeder.pairing in (2 * v_match.pairing, 2 * v_match.pairing + 1)
    and feeder.ends_at <= now();
  if v_match.round = 1 or v_open < 2 then
    raise exception 'this match opens for predictions once both matches before it have ended'
      using errcode = 'P0001';
  end if;
  if new.user_id in (v_match.side_0_user_id, v_match.side_1_user_id) then
    raise exception 'you cannot predict your own match' using errcode = 'P0001';
  end if;
  if new.predicted_user_id not in (v_match.side_0_user_id, v_match.side_1_user_id) then
    raise exception 'pick one of the two managers in that match' using errcode = '22023';
  end if;
  new.saved_at := now();
  return new;
end $$;

create trigger midweek_predictions_guard before insert or update or delete on kut.midweek_predictions
  for each row execute function kut._mm_guard_prediction();
revoke all on function kut._mm_guard_prediction() from public, anon, authenticated;

-- 4. The member's call ------------------------------------------------------------------
-- Saves, changes or (with a null pick) clears the caller's pick for one match,
-- named by round and pairing, since a later round's match is not shown to
-- members before its kick-off. The guard above holds every rule; this checks
-- the caller and finds the match.
create function kut.save_midweek_prediction(
  p_tournament_id uuid,
  p_round integer,
  p_pairing integer,
  p_winner_user_id uuid
)
returns jsonb language plpgsql security definer set search_path = kut, pg_catalog as $$
declare
  v_user uuid := auth.uid();
  v_match_id uuid;
begin
  if v_user is null or not exists (select 1 from kut.profiles where id = v_user and not is_disabled) then
    raise exception 'an active KUT account is required' using errcode = '42501';
  end if;
  if not exists (select 1 from kut.midweek_tournaments where id = p_tournament_id) then
    raise exception 'no such Midweek Madness week' using errcode = 'P0002';
  end if;
  select id into v_match_id from kut.midweek_matches
  where tournament_id = p_tournament_id and round = p_round and pairing = p_pairing;

  if p_winner_user_id is null then
    delete from kut.midweek_predictions where match_id = v_match_id and user_id = v_user;
  else
    if v_match_id is null then
      -- The guard's own order: the member's defeat first, then the match.
      if not exists (
        select 1 from kut.midweek_matches lost
        where lost.tournament_id = p_tournament_id and not lost.bye
          and v_user in (lost.side_0_user_id, lost.side_1_user_id)
          and lost.winner_user_id <> v_user and lost.ends_at <= now()
      ) then
        raise exception 'predictions open once you are out' using errcode = 'P0001';
      end if;
      raise exception 'no such match to predict' using errcode = 'P0002';
    end if;
    insert into kut.midweek_predictions (match_id, user_id, tournament_id, predicted_user_id)
    values (v_match_id, v_user, p_tournament_id, p_winner_user_id)
    on conflict (match_id, user_id) do update
      set predicted_user_id = excluded.predicted_user_id;
  end if;

  return jsonb_build_object(
    'tournament_id', p_tournament_id,
    'round', p_round,
    'pairing', p_pairing,
    'predicted_user_id', p_winner_user_id
  );
end $$;
revoke all on function kut.save_midweek_prediction(uuid, integer, integer, uuid) from public, anon;
grant execute on function kut.save_midweek_prediction(uuid, integer, integer, uuid) to authenticated, service_role;

-- 5. The guard table for the coins --------------------------------------------------------
-- One payment per (week, member), the kut.midweek_rewards pattern: the primary
-- key is the idempotency guard, the ledger row's key
-- 'midweek-prediction:<tournament>:<member>' guards it twice, and the ledger
-- foreign key is deferred because the guard row is written first.
create table kut.midweek_prediction_rewards (
  tournament_id uuid not null references kut.midweek_tournaments(id) on delete restrict,
  user_id uuid not null references kut.profiles(id) on delete restrict,
  picks smallint not null check (picks > 0),
  correct smallint not null check (correct > 0 and correct <= picks),
  amount bigint not null check (amount > 0),
  ledger_id uuid not null references kut.wallet_ledger(id) on delete restrict deferrable initially deferred,
  created_at timestamptz not null default now(),
  primary key (tournament_id, user_id)
);

alter table kut.midweek_prediction_rewards enable row level security;
revoke all on kut.midweek_prediction_rewards from public, anon, authenticated;
grant select on kut.midweek_prediction_rewards to service_role;

comment on table kut.midweek_prediction_rewards is
  'ADR-118, Part L #28: one payment per (Midweek week, member) for correct predictions, at kut._mm_prediction_coins(rounds) a pick. Members read their own through kut.my_midweek_prediction_rewards.';

-- Part L #28, the coins: written only by the complete step, for exactly the
-- member's stored picks and the ones that came true, at the week's rate, never
-- more than 30, and never so much that the week pays the member more than the
-- champion's total with their wins. A paid row never changes.
create function kut._mm_guard_prediction_reward()
returns trigger language plpgsql set search_path = kut, pg_catalog as $$
declare
  v_tournament kut.midweek_tournaments%rowtype;
  v_picks integer;
  v_correct integer;
  v_wins bigint;
begin
  if tg_op = 'UPDATE' then
    raise exception 'a paid Midweek prediction reward is final' using errcode = '55000';
  end if;
  select * into v_tournament from kut.midweek_tournaments where id = new.tournament_id;
  if v_tournament.status is distinct from 'simulated' or v_tournament.final_reveal_at > now() then
    raise exception 'Midweek prediction rewards are paid once, when the final has ended' using errcode = '55000';
  end if;
  select count(*), count(*) filter (where pick.predicted_user_id = played.winner_user_id)
  into v_picks, v_correct
  from kut.midweek_predictions pick
  join kut.midweek_matches played on played.id = pick.match_id
  where pick.tournament_id = new.tournament_id and pick.user_id = new.user_id;
  if new.picks <> v_picks or new.correct <> v_correct then
    raise exception 'a Midweek prediction reward pays the stored picks that came true' using errcode = '23514';
  end if;
  if new.amount <> new.correct * kut._mm_prediction_coins(v_tournament.rounds) or new.amount > 30 then
    raise exception 'a Midweek prediction reward pays the week''s rate a correct pick, at most 30'
      using errcode = '23514';
  end if;
  select coalesce(sum(amount), 0) into v_wins
  from kut.midweek_rewards where tournament_id = new.tournament_id and user_id = new.user_id;
  if v_wins + new.amount > (kut._mm_config()->>'championTotal')::bigint then
    raise exception 'one Midweek tournament pays a member at most %', kut._mm_config()->>'championTotal'
      using errcode = '23514';
  end if;
  return new;
end $$;

create trigger midweek_prediction_rewards_guard before insert or update on kut.midweek_prediction_rewards
  for each row execute function kut._mm_guard_prediction_reward();
revoke all on function kut._mm_guard_prediction_reward() from public, anon, authenticated;

-- 6. The payment, now with correct picks ----------------------------------------------------
-- Wins: exactly 20261013000000_midweek_result_for_everyone.sql section 1.
-- Then each member's correct picks, guard row first, as for a win. Then the
-- same message per entrant, with one sentence more for a member who predicted:
-- "You called 2 of 3 right: +20 KUT Coins." (or "You called 0 of 2 right.",
-- without coins when none were earned).
-- Returns the wins paid, as before.
create or replace function kut._mm_pay_tournament(p_tournament_id uuid)
returns integer language plpgsql security definer set search_path = kut, pg_catalog as $$
declare
  v_tournament kut.midweek_tournaments%rowtype;
  v_pays integer[];
  v_win record;
  v_pick record;
  v_ledger_id uuid;
  v_paid integer := 0;
  v_rate integer;
  v_champion_id uuid;
  v_champion text;
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

  -- Correct picks (ADR-118). A member disabled since the lock is not paid.
  -- Past 32 entrants (six rounds) the rate rounds down to nothing: picks are
  -- still counted in the message, but nothing is paid.
  v_rate := kut._mm_prediction_coins(v_tournament.rounds);
  for v_pick in
    select pick.user_id, count(*) as picks,
      count(*) filter (where pick.predicted_user_id = played.winner_user_id) as correct
    from kut.midweek_predictions pick
    join kut.midweek_matches played on played.id = pick.match_id
    join kut.profiles member on member.id = pick.user_id
    where pick.tournament_id = p_tournament_id and not member.is_disabled and v_rate > 0
    group by pick.user_id
    having count(*) filter (where pick.predicted_user_id = played.winner_user_id) > 0
    order by pick.user_id
  loop
    v_ledger_id := gen_random_uuid();
    insert into kut.midweek_prediction_rewards (tournament_id, user_id, picks, correct, amount, ledger_id)
    values (p_tournament_id, v_pick.user_id, v_pick.picks, v_pick.correct, v_pick.correct * v_rate, v_ledger_id)
    on conflict (tournament_id, user_id) do nothing;
    if not found then continue; end if;

    insert into kut.wallets (user_id, balance) values (v_pick.user_id, 0)
    on conflict (user_id) do nothing;
    insert into kut.wallet_ledger (id, user_id, amount, reason, reference_type, reference_id, idempotency_key)
    values (
      v_ledger_id, v_pick.user_id, v_pick.correct * v_rate, 'midweek_prediction', 'midweek_tournament',
      p_tournament_id, 'midweek-prediction:' || p_tournament_id::text || ':' || v_pick.user_id::text
    );
    update kut.wallets set balance = balance + v_pick.correct * v_rate, updated_at = now()
    where user_id = v_pick.user_id;
  end loop;

  select final.winner_user_id, profile.display_name into v_champion_id, v_champion
  from kut.midweek_matches final
  join kut.profiles profile on profile.id = final.winner_user_id
  where final.tournament_id = p_tournament_id and final.round = v_tournament.rounds;

  -- Every entrant still active (DR1-3): the champion, or the match they lost,
  -- the coins they were paid (byes included), how their picks went, and
  -- whether the engine drew their squad. Opted-out members were never entered;
  -- a member disabled since the lock is neither paid nor told.
  insert into kut.user_notifications (user_id, event_type, title, body, reference_type, reference_id)
  select entry.user_id, 'midweek_result',
    case
      when entry.user_id = v_champion_id then 'You won Midweek Madness'
      else 'You went out in ' || case v_tournament.rounds - lost.round
        when 0 then 'the final'
        when 1 then 'the semi-finals'
        when 2 then 'the quarter-finals'
        else 'round ' || lost.round
      end
    end,
    concat_ws(' ',
      case
        when entry.user_id = v_champion_id then format('%s KUT Coins over the night.', paid.total)
        when lost.side_0_penalties is not null then format('%s beat you on penalties, %s–%s.',
          winner.display_name,
          case lost.winner_side when 0 then lost.side_0_penalties else lost.side_1_penalties end,
          case lost.winner_side when 0 then lost.side_1_penalties else lost.side_0_penalties end)
        else format('%s beat you %s–%s.',
          winner.display_name,
          case lost.winner_side when 0 then lost.side_0_goals else lost.side_1_goals end,
          case lost.winner_side when 0 then lost.side_1_goals else lost.side_0_goals end)
      end,
      case when entry.user_id <> v_champion_id and paid.total > 0
        then format('+%s KUT Coins.', paid.total) end,
      -- Lost the final: the line before already names the champion.
      case when entry.user_id <> v_champion_id and lost.round < v_tournament.rounds
        then format('%s won it.', v_champion) end,
      case
        when called.correct * v_rate > 0 then
          format('You called %s of %s right: +%s KUT Coins.', called.correct, called.picks, called.correct * v_rate)
        when called.picks > 0 then format('You called %s of %s right.', called.correct, called.picks)
      end,
      case when entry.auto then 'Your auto squad played for you.' end
    ),
    'midweek_tournament', p_tournament_id
  from kut.midweek_entries entry
  join kut.profiles member on member.id = entry.user_id and not member.is_disabled
  left join lateral (
    select coalesce(sum(reward.amount), 0) as total
    from kut.midweek_rewards reward
    where reward.tournament_id = p_tournament_id and reward.user_id = entry.user_id
  ) paid on true
  left join lateral (
    select count(*) as picks, count(*) filter (where pick.predicted_user_id = played.winner_user_id) as correct
    from kut.midweek_predictions pick
    join kut.midweek_matches played on played.id = pick.match_id
    where pick.tournament_id = p_tournament_id and pick.user_id = entry.user_id
  ) called on true
  left join kut.midweek_matches lost
    on lost.tournament_id = p_tournament_id and not lost.bye
    and entry.user_id in (lost.side_0_user_id, lost.side_1_user_id)
    and lost.winner_user_id <> entry.user_id
  left join kut.profiles winner on winner.id = lost.winner_user_id
  where entry.tournament_id = p_tournament_id
    and (entry.user_id = v_champion_id or lost.id is not null)
  on conflict (user_id, event_type, reference_type, reference_id)
    where reference_type is not null and reference_id is not null do nothing;

  return v_paid;
end $$;
revoke all on function kut._mm_pay_tournament(uuid) from public, anon, authenticated;

-- 7. Views -------------------------------------------------------------------------------------
-- The caller's own picks, with whether each came true once its match has
-- ended. A definer view gated on kut.is_active_member() (ADR-079).
create view kut.my_midweek_predictions
with (security_invoker = false, security_barrier = true)
as
select
  pick.tournament_id,
  tournament.week_start,
  played.round,
  played.pairing,
  pick.predicted_user_id,
  predicted.display_name as predicted_name,
  pick.saved_at,
  case when played.ends_at <= now() then pick.predicted_user_id = played.winner_user_id end as correct
from kut.midweek_predictions pick
join kut.midweek_matches played on played.id = pick.match_id
join kut.midweek_tournaments tournament on tournament.id = pick.tournament_id
join kut.profiles predicted on predicted.id = pick.predicted_user_id
where pick.user_id = auth.uid()
  and tournament.status <> 'void'
  and kut.is_active_member();

comment on view kut.my_midweek_predictions is
  'ADR-118: the caller''s own Midweek predictions; correct is null until the match has ended. Gated on kut.is_active_member() (ADR-079).';
revoke all on kut.my_midweek_predictions from public, anon;
grant select on kut.my_midweek_predictions to authenticated, service_role;

-- The caller's own prediction coins, one row per week paid.
create view kut.my_midweek_prediction_rewards
with (security_invoker = false, security_barrier = true)
as
select
  reward.tournament_id,
  tournament.week_start,
  reward.picks,
  reward.correct,
  reward.amount,
  reward.created_at as paid_at
from kut.midweek_prediction_rewards reward
join kut.midweek_tournaments tournament on tournament.id = reward.tournament_id
where reward.user_id = auth.uid()
  and kut.is_active_member();

comment on view kut.my_midweek_prediction_rewards is
  'ADR-118: the caller''s own Midweek prediction coins, one row per week paid. Gated on kut.is_active_member() (ADR-079).';
revoke all on kut.my_midweek_prediction_rewards from public, anon;
grant select on kut.my_midweek_prediction_rewards to authenticated, service_role;

-- How the club split on each match, from its kick-off: counts only, never who.
create view kut.midweek_prediction_splits_public
with (security_invoker = false, security_barrier = true)
as
select
  played.id as match_id,
  played.tournament_id,
  played.round,
  played.pairing,
  count(*) filter (where pick.predicted_user_id = played.side_0_user_id)::integer as side_0_picks,
  count(*) filter (where pick.predicted_user_id = played.side_1_user_id)::integer as side_1_picks
from kut.midweek_matches played
join kut.midweek_tournaments tournament on tournament.id = played.tournament_id
join kut.midweek_predictions pick on pick.match_id = played.id
where played.reveal_at <= now()
  and tournament.status in ('simulated', 'complete')
  and kut.is_active_member()
group by played.id, played.tournament_id, played.round, played.pairing;

comment on view kut.midweek_prediction_splits_public is
  'ADR-118: per match, how many members who were out picked each side, from its kick-off. Never who. Gated on kut.is_active_member() (ADR-079).';
revoke all on kut.midweek_prediction_splits_public from public, anon;
grant select on kut.midweek_prediction_splits_public to authenticated, service_role;
