-- Midweek Madness 2.0, B3: the evening unfolds event by event (BUILD_SPEC §44.9,
-- §44.14; ADR-106, amending ADR-095 and ADR-105; design/ux-review/HANDOFF.md
-- "Data the screens need" and "No full-time estimates").
--
-- Until now a match was readable whole from its kick-off: its goals, winner and
-- every event. ADR-104 stored each event's moment (midweek_match_events.reveal_at)
-- and each match's end (midweek_matches.ends_at) at the lock; this migration
-- makes the member views follow them, for every match alike (uniform pacing,
-- owner decision Q7):
--
--   1. kut.midweek_matches_public  -- the pairing, kick-off, win chance and day
--                                      rolls from kick-off, as before; goals,
--                                      penalties and the winner only from the
--                                      match's end. Appends ends_at, only once
--                                      it has passed (a late end would give a
--                                      shoot-out away), and in_play (kicked
--                                      off, not ended).
--   2. kut.midweek_events_public   -- an event only from its own moment.
--                                      Appends reveal_at.
--   3. kut.midweek_tournaments_public
--                                  -- the champion only from the end of the
--                                      final, not its kick-off.
--
-- Weeks simulated before ADR-104 have no event times and no end: they keep
-- revealing whole matches at kick-off, exactly as drawn.
--
-- Deploy ordering: this changes what today's pages read. A match in play now
-- reads with a null winner, which pages from before F6 would show as a loss.
-- So F6 (which renders the live match on the server from the stored rows and
-- reads every row tolerantly) must be deployed before this push, and the push
-- must not land during a running Wednesday evening (ADR-106).
--
-- Tier: additive (docs/OPERATIONS.md): views only; columns are appended, no
-- table, function or row changes.
--
-- Rollback: re-create kut.midweek_matches_public and kut.midweek_events_public
-- from 20261005000000_midweek_engine.sql section 5 (drop them first: a view
-- cannot lose a column) and re-apply their grants and comments; re-create
-- kut.midweek_tournaments_public from 20261012000000_midweek_draw_from_lock.sql
-- section 3 (same columns, so create or replace works).

-- 1. Matches: the result from full time --------------------------------------------------
-- A match is visible from its kick-off (reveal_at), as before. What decides it
-- (goals, penalties, winner) waits for its end; so does the end itself, since
-- an end later than full time means a shoot-out. A bye ends as it starts.
create or replace view kut.midweek_matches_public
with (security_invoker = false, security_barrier = true)
as
select
  played.id as match_id,
  played.tournament_id,
  tournament.week_start,
  played.round,
  played.pairing,
  played.bye,
  played.side_0_user_id,
  side_0.display_name as side_0_name,
  played.side_1_user_id,
  side_1.display_name as side_1_name,
  case when ended.ended then played.side_0_goals end as side_0_goals,
  case when ended.ended then played.side_1_goals end as side_1_goals,
  case when ended.ended then played.side_0_penalties end as side_0_penalties,
  case when ended.ended then played.side_1_penalties end as side_1_penalties,
  case when ended.ended then played.winner_side end as winner_side,
  case when ended.ended then played.winner_user_id end as winner_user_id,
  played.win_chance_ppm,
  played.side_0_day_rolls_ppm,
  played.side_1_day_rolls_ppm,
  played.reveal_at,
  case when ended.ended then played.ends_at end as ends_at,
  not ended.ended as in_play
from kut.midweek_matches played
join kut.midweek_tournaments tournament on tournament.id = played.tournament_id
join kut.profiles side_0 on side_0.id = played.side_0_user_id
left join kut.profiles side_1 on side_1.id = played.side_1_user_id
cross join lateral (
  -- Before ADR-104 a match has no end and shows whole from its kick-off.
  select played.ends_at is null or played.ends_at <= now() as ended
) ended
where kut.is_active_member()
  and tournament.status in ('simulated', 'complete')
  and played.reveal_at <= now();

comment on view kut.midweek_matches_public is
  'ADR-095, ADR-106: Midweek Madness pairings from their kick-off, byes included, with the pre-match win chance and each card''s day roll; goals, penalties, the winner and ends_at only once the match has ended, and in_play until then. Gated on kut.is_active_member() (ADR-079).';

-- 2. Events: each from its own moment ---------------------------------------------------
create or replace view kut.midweek_events_public
with (security_invoker = false, security_barrier = true)
as
select
  event.match_id,
  played.tournament_id,
  played.round,
  played.pairing,
  event.seq,
  event.kind,
  event.side,
  event.minute,
  event.penalty_round,
  event.creator_slot,
  event.shooter_slot,
  event.defender_slot,
  event.kicker_slot,
  event.keeper_slot,
  event.chance_type,
  event.outcome,
  event.p_goal_ppm,
  event.reveal_at
from kut.midweek_match_events event
join kut.midweek_matches played on played.id = event.match_id
join kut.midweek_tournaments tournament on tournament.id = played.tournament_id
where kut.is_active_member()
  and tournament.status in ('simulated', 'complete')
  and played.reveal_at <= now()
  -- Before ADR-104 an event has no moment and shows with its match.
  and coalesce(event.reveal_at, played.reveal_at) <= now();

comment on view kut.midweek_events_public is
  'ADR-095, ADR-106: the events of Midweek Madness matches (chances, penalty kicks, a settling draw), engine slots 0-4, each from its own moment (reveal_at), or with its match before ADR-104. Gated on kut.is_active_member() (ADR-079).';

-- 3. The champion from the end of the final ------------------------------------------------
create or replace view kut.midweek_tournaments_public
with (security_invoker = false, security_barrier = true)
as
select
  tournament.id as tournament_id,
  tournament.week_start,
  tournament.lock_at,
  tournament.seed_hash,
  tournament.status,
  tournament.status_reason,
  tournament.void_note,
  tournament.rounds,
  case when tournament.final_reveal_at <= now() then tournament.final_reveal_at end as final_reveal_at,
  tournament.seed,
  champion.user_id as champion_user_id,
  champion.display_name as champion_name,
  tournament.schedule_version
from kut.midweek_tournaments tournament
left join lateral (
  select final.winner_user_id as user_id, profile.display_name
  from kut.midweek_matches final
  join kut.profiles profile on profile.id = final.winner_user_id
  where final.tournament_id = tournament.id
    and final.round = tournament.rounds
    and tournament.status in ('simulated', 'complete')
    and coalesce(final.ends_at, final.reveal_at) <= now()
) champion on true
where kut.is_active_member()
order by tournament.week_start desc;

comment on view kut.midweek_tournaments_public is
  'ADR-089, ADR-095, ADR-104, ADR-105, ADR-106: every Midweek Madness tournament (status, skip or void reason, lock, final_reveal_at once passed, the seed only once complete, the version of its clock) and its champion once the final has ended. Gated on kut.is_active_member() (ADR-079).';
