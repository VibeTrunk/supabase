-- Midweek Madness 2.0, B2: what members see from the lock (BUILD_SPEC §44.9,
-- §44.14; ADR-105, amending ADR-091, ADR-095, ADR-098 and ADR-104).
--
-- Between the lock (19:55) and round 1 (20:00) the evening page shows the draw
-- and every entered five (design/ux-review/HANDOFF.md, "Data the screens
-- need"), but nothing that hints at a result: no score, no winner, no match
-- end, and none of the week's dice.
--
--   1. kut.midweek_draw_public        -- new: round 1's pairings and byes, both
--                                         managers and the kick-off, from the
--                                         lock. No result column at all.
--   2. kut.midweek_entries_public     -- from the lock instead of round 1. The
--                                         week's dice and pick shares
--                                         (form_roll_ppm, pick_factor_ppm,
--                                         power_ppm) read null until round 1
--                                         starts. Columns unchanged; picks and
--                                         owner counts keep owner decision D3.
--   3. kut.midweek_current / kut.midweek_tournaments_public
--                                     -- final_reveal_at only once it has
--                                         passed: since ADR-104 it is the end
--                                         of the final, so at the lock its
--                                         distance from the final's kick-off
--                                         told an API reader whether the final
--                                         goes to penalties. No page reads it;
--                                         the worker and the admin page read
--                                         the table.
--   4. kut.midweek_current            -- appends evening_live (the week is
--                                         drawn, and now is between the lock
--                                         and the end of the final) for the
--                                         Compete badge.
--
-- Matches and events are still revealed whole at their start (§44.9); event by
-- event is ADR-106's migration.
--
-- Deploy ordering: Vercel deploys on merge, before this push. Pages read every
-- view with select("*"); the new view is read only by later frontend PRs, and
-- evening_live is read tolerantly (absent = not live). No page reads
-- final_reveal_at from a member view.
--
-- Tier: additive (docs/OPERATIONS.md). Views only; no table, function or row
-- changes.
--
-- Rollback:
--   drop view kut.midweek_draw_public;
--   re-create kut.midweek_entries_public from 20261005000000_midweek_engine.sql
--     section 5 (same columns, so create or replace works);
--   drop and re-create kut.midweek_current and kut.midweek_tournaments_public
--     from 20261011000000_midweek_evening_timing.sql section 7 (midweek_current
--     must be dropped: a view cannot lose a column), then re-apply their grants
--     from 20261003000000_midweek_entry.sql.

-- 1. The draw ---------------------------------------------------------------------
-- Round 1 as drawn at the lock: each pairing's position, a bye (one entrant,
-- side 0, which counts as a win and is no secret), both managers, and the
-- kick-off, which the lock step stored as the match's reveal_at (round 1's start
-- on the week's clock, ADR-104). Goals, penalties, winner, win chance, day rolls
-- and ends_at stay in kut.midweek_matches_public, from kick-off.
create view kut.midweek_draw_public
with (security_invoker = false, security_barrier = true)
as
select
  played.id as match_id,
  played.tournament_id,
  tournament.week_start,
  played.pairing,
  played.bye,
  played.side_0_user_id,
  side_0.display_name as side_0_name,
  played.side_1_user_id,
  side_1.display_name as side_1_name,
  played.reveal_at as kickoff_at
from kut.midweek_matches played
join kut.midweek_tournaments tournament on tournament.id = played.tournament_id
join kut.profiles side_0 on side_0.id = played.side_0_user_id
left join kut.profiles side_1 on side_1.id = played.side_1_user_id
where kut.is_active_member()
  and tournament.status in ('simulated', 'complete')
  and tournament.lock_at <= now()
  and played.round = 1;

comment on view kut.midweek_draw_public is
  'ADR-105: round 1 of a drawn Midweek Madness week from the lock: pairings, byes, both managers and the kick-off, with no result. Gated on kut.is_active_member() (ADR-079).';

revoke all on kut.midweek_draw_public from public, anon;
grant select on kut.midweek_draw_public to authenticated, service_role;

-- 2. Entries from the lock ---------------------------------------------------------
-- As in 20261005000000_midweek_engine.sql section 5, except when: every entered
-- card shows from the lock (the five, OVR, archetype, injury, trialist, auto,
-- the keeper), and the three columns that carry the week's dice and the pick
-- shares wait for round 1's kick-off. The deterministic factors (OVR factor,
-- fitness, handicap, line multipliers) show from the lock.
create or replace view kut.midweek_entries_public
with (security_invoker = false, security_barrier = true)
as
select
  entry.tournament_id,
  tournament.week_start,
  entry.user_id,
  manager.display_name as manager_name,
  entry.auto,
  entry.keeper_slot,
  entry.keeperless,
  card.slot,
  card.trialist,
  card.player_id,
  player.display_name as player_name,
  player.photo_path,
  card.ovr,
  card.archetype,
  card.injured,
  card.ovr_factor_ppm,
  case when kickoff.started then card.form_roll_ppm end as form_roll_ppm,
  case when kickoff.started then card.pick_factor_ppm end as pick_factor_ppm,
  card.fitness_ppm,
  card.handicap_ppm,
  case when kickoff.started then card.power_ppm end as power_ppm,
  card.att_ppm,
  card.mid_ppm,
  card.def_ppm,
  case when tournament.status = 'complete' then share.picks end as picks,
  case when tournament.status = 'complete' and share.owners >= 3 then share.owners end as owners
from kut.midweek_entries entry
join kut.midweek_tournaments tournament on tournament.id = entry.tournament_id
join kut.profiles manager on manager.id = entry.user_id
join kut.midweek_entry_cards card on card.tournament_id = entry.tournament_id and card.user_id = entry.user_id
left join kut.players player on player.id = card.player_id
left join kut.midweek_pick_shares share on share.tournament_id = card.tournament_id and share.player_id = card.player_id
cross join lateral (
  select exists (
    select 1 from kut.midweek_matches first_round
    where first_round.tournament_id = entry.tournament_id and first_round.round = 1
      and first_round.reveal_at <= now()) as started
) kickoff
where kut.is_active_member()
  and tournament.status in ('simulated', 'complete')
  and tournament.lock_at <= now();

comment on view kut.midweek_entries_public is
  'ADR-091, ADR-095, ADR-105: every entered Midweek Madness card (engine slots 0-4) with its lock-time OVR, archetype, injury flag and factors, from the lock; form roll, pick factor and power only from round 1''s kick-off. Picks and owner counts only once complete; owners null below three. Gated on kut.is_active_member() (ADR-079).';

-- 3 and 4. The tournament rows: final_reveal_at once passed, evening_live --------
-- As in 20261011000000_midweek_evening_timing.sql section 7, with
-- final_reveal_at null until it has passed and, on midweek_current only,
-- evening_live appended. A week the worker hasn't drawn yet isn't live: it may
-- still be skipped.
create or replace view kut.midweek_current
with (security_invoker = false, security_barrier = true)
as
select * from (
  select
    config.enabled,
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
    exists (select 1 from kut.midweek_opt_outs o where o.user_id = auth.uid()) as opted_out,
    tournament.schedule_version,
    coalesce(tournament.status = 'simulated' and tournament.lock_at <= now()
      and now() < tournament.final_reveal_at, false) as evening_live
  from kut.midweek_config config
  left join lateral (
    select * from kut.midweek_tournaments order by week_start desc limit 1
  ) tournament on true
) gated
where kut.is_active_member();

comment on view kut.midweek_current is
  'ADR-089, ADR-104, ADR-105: the Midweek Madness launch switch, the latest tournament (seed hash from creation, final_reveal_at once passed, seed only once complete, the version of its clock), the caller''s opt-out, and whether its evening is live (drawn, between the lock and the end of the final). Gated on kut.is_active_member() (ADR-079).';

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
    and final.reveal_at <= now()
) champion on true
where kut.is_active_member()
order by tournament.week_start desc;

comment on view kut.midweek_tournaments_public is
  'ADR-089, ADR-095, ADR-104, ADR-105: every Midweek Madness tournament (status, skip or void reason, lock, final_reveal_at once passed, the seed only once complete, the version of its clock) and its champion once the final is revealed. Gated on kut.is_active_member() (ADR-079).';
