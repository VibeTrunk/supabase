-- Midweek Madness 2.0, PR 5: a result message for every entrant (BUILD_SPEC
-- §44.7, §44.14; ADR-109, amending ADR-096; owner decision DR1-3 in
-- design/ux-review/HANDOFF.md).
--
-- ADR-096 messaged only the members it paid, so a member out in round 1
-- without a bye heard nothing: 5 of 21 on 30 Sep. Now every entrant still
-- active at the payout gets one `midweek_result` message, worded by how far
-- they got (HANDOFF "Messages"):
--
--   champion             You won Midweek Madness
--                        250 KUT Coins over the night.
--   out, with coins      You went out in the quarter-finals
--                        Sophie beat you on penalties, 7–6. +50 KUT Coins. Joris won it.
--   out, with nothing    You went out in round 1
--                        Emma beat you 2–1. Joris won it.
--   an auto squad        ... Your auto squad played for you.
--
-- The score is the winner's first; a shoot-out gives the penalties instead of
-- the drawn score. The runner-up's message leaves out who won it, since the
-- line before says so. The reference stays the tournament, so the inbox links the
-- message to that week's bracket (ADR-114).
--
--   1. kut._mm_pay_tournament   -- re-created. The payment part is unchanged
--                                   word for word: same rewards, ledger rows,
--                                   wallets and return value (Part L #26
--                                   untouched). Only the message step changes:
--                                   one per entrant not disabled, with a title
--                                   by finish, instead of one per member paid
--                                   titled "Midweek Madness".
--
-- Idempotent as before: the inbox's unique index on (user, type, reference)
-- takes each message once, and the complete step runs the function only while
-- the week is simulated, under its row lock.
--
-- Deploy ordering: no page reads the message text. Vercel deploying before the
-- push changes nothing; a week paid before the push keeps its old messages.
--
-- Tier: data-changing (docs/OPERATIONS.md): it changes what the worker writes
-- when it pays a week. Fresh cold-verified backup before the push.
--
-- Rollback: re-create kut._mm_pay_tournament from
-- 20261006000000_midweek_payouts.sql section 4 (same signature, so create or
-- replace works), then re-apply its revoke.

-- 1. The payment, and a message for every entrant -------------------------------------
create or replace function kut._mm_pay_tournament(p_tournament_id uuid)
returns integer language plpgsql security definer set search_path = kut, pg_catalog as $$
declare
  v_tournament kut.midweek_tournaments%rowtype;
  v_pays integer[];
  v_win record;
  v_ledger_id uuid;
  v_paid integer := 0;
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

  select final.winner_user_id, profile.display_name into v_champion_id, v_champion
  from kut.midweek_matches final
  join kut.profiles profile on profile.id = final.winner_user_id
  where final.tournament_id = p_tournament_id and final.round = v_tournament.rounds;

  -- Every entrant still active (DR1-3): the champion, or the match they lost,
  -- the coins they were paid (byes included), and whether the engine drew
  -- their squad. Opted-out members were never entered; a member disabled
  -- since the lock is neither paid nor told.
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
