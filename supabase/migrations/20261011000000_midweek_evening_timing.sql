-- Midweek Madness 2.0, B1: the evening's new clock (BUILD_SPEC §44.1, §44.7,
-- §44.11, §44.14, §145; Part L #25; ADR-104, amending ADR-089 and ADR-096).
--
-- Squads lock at 19:55 and round r starts at lock + 5 min + 15 min × (r − 1),
-- so with 17-32 entrants the final starts at 21:00 instead of 22:30. Every
-- event of a match gets its own moment: the match clock runs from 0' to 90'
-- over the 14 chance slots of 20 seconds (4:40), and after full time a
-- shoot-out kick follows every 5 seconds. The payout, the seed and the pick
-- shares wait for the end of the final, not its start.
--
-- A week keeps the clock it opened with (Part L #25), so the clock is
-- versioned: version 1 is every week up to now (lock 20:00, round r revealed
-- whole 30 min × r later), version 2 the new evening. The pages read the
-- version from the tournament and compute every time from it.
--
--   1. kut._mm_config()                -- `schedule` becomes {lockDayOffset,
--                                         current, versions: {1, 2}}; every
--                                         other key unchanged (parity test).
--   2. kut._mm_schedule, _mm_lock_at(date, int), _mm_round_start_at,
--      _mm_match_timing               -- the clock, twins of
--                                         src/game/midweek/schedule.ts.
--                                         _mm_lock_at(date) now means the
--                                         current version; _mm_reveal_at goes.
--   3. kut.midweek_tournaments.schedule_version, midweek_matches.ends_at and
--      midweek_match_events.reveal_at -- written by the lock step; null on the
--                                         rows of weeks already simulated,
--                                         which keep revealing whole matches.
--   4. Part L #25                      -- the schedule version is fixed once
--                                         a week has locked; ends_at and the
--                                         event times are insert-only through
--                                         the existing result guard.
--   5. The worker                      -- the open step stamps the current
--                                         version; the lock step writes the
--                                         times, and final_reveal_at becomes
--                                         the end of the final, which is what
--                                         the complete step and the reward
--                                         guard already wait for.
--   6. kut.admin_midweek_rehearsal     -- round starts on the week's clock,
--                                         each round's end, and the version.
--   7. kut.midweek_current / kut.midweek_tournaments_public -- append
--                                         schedule_version.
--   8. The open week moves to version 2 -- its lock from 20:00 to 19:55,
--                                         unless that is already past.
--
-- The views still reveal a match whole at its start (§44.9); revealing it event
-- by event is ADR-106's migration. Until then the new times only move when
-- rounds come out and when the week is paid.
--
-- Deploy ordering: Vercel deploys on merge, before this push. The pages read
-- both views with select("*") and treat a row without schedule_version as
-- version 1, which is what every hosted week is until this lands.
--
-- Tier: data-changing (docs/OPERATIONS.md). It re-times the open tournament's
-- lock and changes when the payout runs. Fresh cold-verified backup first.
--
-- Rollback (no week simulated on version 2 yet, or accept that it reverts to
-- whole-match reveal):
--   update kut.midweek_tournaments set lock_at = kut._mm_lock_at(week_start, 1), schedule_version = 1
--     where status = 'open' and schedule_version = 2;   -- before the guard is re-created
--   re-create kut.midweek_current and kut.midweek_tournaments_public from
--     20261003000000_midweek_entry.sql and 20261005000000_midweek_engine.sql
--     (drop them first: a view cannot lose columns);
--   re-create kut._mm_config, kut._mm_lock_at(date), kut._mm_reveal_at,
--     kut._mm_guard_tournament, kut._mm_lock_tournament, kut._mm_open_next and
--     kut.admin_midweek_rehearsal from 20261005000000_midweek_engine.sql;
--   drop function kut._mm_match_timing(jsonb, integer); drop function kut._mm_round_start_at(timestamptz, integer, integer);
--   drop function kut._mm_lock_at(date, integer); drop function kut._mm_schedule(integer);
--   alter table kut.midweek_match_events drop column reveal_at;
--   alter table kut.midweek_matches drop column ends_at;
--   alter table kut.midweek_tournaments drop column schedule_version;

-- 1. The configuration -------------------------------------------------------------
-- Verbatim from MIDWEEK in src/game/midweek/config.ts; the parity test compares
-- it with tests/fixtures/midweek-golden.json key for key.
create or replace function kut._mm_config()
returns jsonb language sql immutable parallel safe set search_path = kut, pg_catalog as $$
  select '{"squadSize":5,"minEntrants":4,"championTotal":250,"ownerCountMin":3,"schedule":{"lockDayOffset":2,"current":2,"versions":{"1":{"lockHourLocal":20,"lockMinuteLocal":0,"roundOffsetMinutes":30,"roundIntervalMinutes":30,"slotSeconds":0,"kickSeconds":0},"2":{"lockHourLocal":19,"lockMinuteLocal":55,"roundOffsetMinutes":5,"roundIntervalMinutes":15,"slotSeconds":20,"kickSeconds":5}}},"ovr":{"min":30,"max":83,"factorMaxPpm":1100000},"form":{"minPpm":800000,"modePpm":1000000,"maxPpm":1250000,"dice":2},"pick":{"points":[[0,1250000],[400000,1000000],[1000000,875000]],"smoothingPicks":1,"smoothingOwners":3,"neutralPpm":1000000},"dayRollSpreadPpm":120000,"injuredFitnessPpm":950000,"autoFactorPpm":575000,"trialist":{"ovr":30,"factorPpm":825000},"shape":{"scalePpm":500000,"minMultPpm":100000},"keeperlessFactorPpm":450000,"keeperCreatorWeightPpm":150000,"keeperShooterWeightPpm":5000,"match":{"intendedGoalsPerMatch":2.5,"chanceSlots":14,"chanceRatePpm":686000,"midfieldContrast":1,"goalBasePpm":300000,"finishingContrast":1,"goalMinPpm":20000,"goalMaxPpm":850000,"minutes":90,"missWeights":{"save":45,"block":25,"woodwork":8,"wide":22}},"penalties":{"kicks":5,"basePpm":750000,"contrast":1,"minPpm":400000,"maxPpm":950000,"maxSuddenDeathRounds":20,"missWeights":{"save":60,"woodwork":15,"wide":25}},"winChanceContrast":3,"chanceTypes":{"solo":["breakaway","wing_run","long_shot","curler","scramble","free_kick"],"base":{"breakaway":3,"wing_run":3,"chase":2,"volley":2,"first_time":4,"overhead":0,"through_ball":4,"free_kick":2,"curler":3,"header":3,"scramble":4,"long_shot":3,"long_throw":0,"cutback":5,"one_two":4},"creatorBonus":{"all_rounder":{},"speedster":{"wing_run":5,"cutback":3},"finisher":{"one_two":2},"playmaker":{"through_ball":6,"free_kick":3,"one_two":3},"defender":{"header":2,"scramble":2},"tank":{"header":2,"scramble":2},"goalkeeper":{"long_throw":8,"breakaway":3}},"shooterBonus":{"all_rounder":{},"speedster":{"breakaway":6,"chase":6,"wing_run":2},"finisher":{"volley":5,"first_time":6,"overhead":1},"playmaker":{"curler":5,"free_kick":4},"defender":{"header":6,"scramble":4,"long_shot":3},"tank":{"header":6,"scramble":4,"long_shot":4},"goalkeeper":{"long_shot":2}},"difficultyPpm":{"breakaway":1200000,"wing_run":850000,"chase":1000000,"volley":800000,"first_time":1000000,"overhead":400000,"through_ball":1100000,"free_kick":550000,"curler":700000,"header":900000,"scramble":1150000,"long_shot":450000,"long_throw":900000,"cutback":1250000,"one_two":1100000}}}'::jsonb
$$;

-- 2. The clock -----------------------------------------------------------------------

-- schedule.ts `scheduleFor`: one version of the evening's clock.
create function kut._mm_schedule(p_version integer)
returns jsonb language plpgsql immutable parallel safe set search_path = kut, pg_catalog as $$
declare v_schedule jsonb := kut._mm_config()#>array['schedule', 'versions', p_version::text];
begin
  if v_schedule is null then
    raise exception 'Unknown Midweek schedule version %', p_version using errcode = '22023';
  end if;
  return v_schedule;
end $$;

-- schedule.ts `lockAt`: Wednesday at the version's lock time, Europe/Amsterdam,
-- of the football week starting on this ISO Monday.
create function kut._mm_lock_at(p_week_start date, p_version integer)
returns timestamptz language plpgsql stable parallel safe set search_path = kut, pg_catalog as $$
declare
  c jsonb := kut._mm_config()->'schedule';
  s jsonb := kut._mm_schedule(p_version);
begin
  if p_week_start is null or extract(isodow from p_week_start) <> 1 then
    raise exception 'Expected an ISO Monday, received %', p_week_start using errcode = '22023';
  end if;
  return ((p_week_start + (c->>'lockDayOffset')::int)
    + make_time((s->>'lockHourLocal')::int, (s->>'lockMinuteLocal')::int, 0))
    at time zone 'Europe/Amsterdam';
end $$;

-- The lock of a week that opens now, on the current version: the open step,
-- kut._mm_next_week and the payout message read it.
create or replace function kut._mm_lock_at(p_week_start date)
returns timestamptz language sql stable parallel safe set search_path = kut, pg_catalog as $$
  select kut._mm_lock_at(p_week_start, (kut._mm_config()#>>'{schedule,current}')::int)
$$;

-- schedule.ts `roundStartAt`: round r starts roundOffset + roundInterval × (r − 1)
-- minutes after the lock. Version 1 is 30 min × r, as before.
create function kut._mm_round_start_at(p_lock_at timestamptz, p_round integer, p_version integer)
returns timestamptz language sql immutable strict parallel safe set search_path = kut, pg_catalog as $$
  select p_lock_at + make_interval(mins =>
    (kut._mm_schedule(p_version)->>'roundOffsetMinutes')::int
    + (kut._mm_schedule(p_version)->>'roundIntervalMinutes')::int * (p_round - 1))
$$;

-- schedule.ts `matchTiming`: each event's moment in milliseconds after kick-off,
-- from the engine's events. A chance is due when the clock reaches its minute
-- (minute × slots × slotSeconds / 90), each shoot-out kick and a settling draw
-- one kickSeconds after the one before, from full time. Version 1 is all zero.
create function kut._mm_match_timing(p_events jsonb, p_version integer)
returns jsonb language plpgsql immutable parallel safe set search_path = kut, pg_catalog as $$
declare
  m jsonb := kut._mm_config()->'match';
  s jsonb := kut._mm_schedule(p_version);
  v_regulation bigint := (m->>'chanceSlots')::bigint * (s->>'slotSeconds')::bigint * 1000;
  v_kick bigint := (s->>'kickSeconds')::bigint * 1000;
  v_after bigint := 0;
  v_offsets jsonb := '[]'::jsonb;
  v_event jsonb;
begin
  for v_event in
    select event.value from jsonb_array_elements(coalesce(p_events, '[]'::jsonb)) with ordinality as event(value, ord)
    order by event.ord
  loop
    if v_event->>'kind' = 'chance' then
      v_offsets := v_offsets || jsonb_build_array((v_event->>'minute')::bigint * v_regulation / (m->>'minutes')::bigint);
    else
      v_after := v_after + 1;
      v_offsets := v_offsets || jsonb_build_array(v_regulation + v_after * v_kick);
    end if;
  end loop;
  return jsonb_build_object('eventOffsetsMs', v_offsets, 'endOffsetMs', v_regulation + v_after * v_kick);
end $$;

drop function kut._mm_reveal_at(timestamptz, integer);

-- 3. Stored times ---------------------------------------------------------------------
-- Weeks already simulated keep version 1 and null times: they reveal whole
-- matches at reveal_at, as they were drawn. A new week opens on the current
-- version; kut._mm_open_next names it, and the default covers a hand insert.
alter table kut.midweek_tournaments
  add column schedule_version smallint not null default 1 check (schedule_version between 1 and 2);

comment on column kut.midweek_tournaments.schedule_version is
  'ADR-104: the version of the evening''s clock this week follows (MIDWEEK.schedule.versions). Fixed once the week locks (Part L #25).';

-- A match's end: full time, or its shoot-out's last kick or settling draw.
-- reveal_at stays the moment the match starts.
alter table kut.midweek_matches
  add column ends_at timestamptz,
  add constraint midweek_matches_ends_at_check check (ends_at is null or ends_at >= reveal_at);

comment on column kut.midweek_matches.ends_at is
  'ADR-104: when the match ends (equal to reveal_at for a bye and on version 1). Null on weeks simulated before ADR-104.';

alter table kut.midweek_match_events add column reveal_at timestamptz;

comment on column kut.midweek_match_events.reveal_at is
  'ADR-104: when the event is due, between its match''s reveal_at and ends_at. Null on weeks simulated before ADR-104.';

-- 4. Part L #25: the clock is fixed once a week locks ----------------------------------
-- As in 20261005000000_midweek_engine.sql section 3, plus the schedule version.
-- ends_at and the event times need nothing new: kut._mm_guard_result already
-- refuses every update to a stored result.
create or replace function kut._mm_guard_tournament()
returns trigger language plpgsql set search_path = kut, pg_catalog as $$
begin
  if new.week_start is distinct from old.week_start or new.seed_hash is distinct from old.seed_hash then
    raise exception 'a Midweek tournament''s week and seed hash never change' using errcode = '55000';
  end if;
  if old.status <> 'open' and new.lock_at is distinct from old.lock_at then
    raise exception 'a Midweek tournament''s lock is fixed once it has locked' using errcode = '55000';
  end if;
  if old.status <> 'open' and new.schedule_version is distinct from old.schedule_version then
    raise exception 'a Midweek tournament''s schedule is fixed once it has locked' using errcode = '55000';
  end if;
  if old.rounds is not null and (new.rounds is distinct from old.rounds
    or new.final_reveal_at is distinct from old.final_reveal_at) then
    raise exception 'a Midweek bracket is drawn once' using errcode = '55000';
  end if;
  if new.status is distinct from old.status and not (
    (old.status = 'open' and new.status in ('skipped', 'simulated', 'void'))
    or (old.status = 'simulated' and new.status in ('complete', 'void'))
  ) then
    raise exception 'a Midweek tournament cannot go from % to %', old.status, new.status using errcode = '55000';
  end if;
  if new.seed is not null and encode(sha256(decode(new.seed, 'hex')), 'hex') <> new.seed_hash then
    raise exception 'the published seed must match the seed hash' using errcode = '55000';
  end if;
  return new;
end $$;

-- 5. The worker ------------------------------------------------------------------------

-- As in 20261005000000_midweek_engine.sql section 4, except the times: each
-- pairing starts on the week's clock and ends when its last event is due (a
-- bye ends as it starts), each event stores its moment, and the final's end is
-- final_reveal_at, so the complete step pays only once the final is over.
create or replace function kut._mm_lock_tournament(p_tournament_id uuid)
returns text language plpgsql security definer set search_path = kut, pg_catalog as $$
declare
  v_tournament kut.midweek_tournaments%rowtype;
  v_seed text; v_result jsonb; v_rounds integer;
begin
  select * into v_tournament from kut.midweek_tournaments where id = p_tournament_id for update;
  if not found or v_tournament.status <> 'open' or v_tournament.lock_at > now() then return 'not_due'; end if;

  if not kut._mm_club_played(v_tournament.week_start) then
    update kut.midweek_tournaments set status = 'skipped', status_reason = 'club_break', updated_at = now()
    where id = p_tournament_id;
    return 'skipped';
  end if;

  select seed into v_seed from kut.midweek_tournament_secrets where tournament_id = p_tournament_id;
  if v_seed is null then raise exception 'Midweek tournament % has no seed', p_tournament_id; end if;
  -- Opt-outs count as of the lock (§44.2); everything else as the worker finds it.
  v_result := kut._mm_simulate(decode(v_seed, 'hex'),
    kut._mm_field(p_tournament_id, v_tournament.lock_at)->'entrants');

  if v_result->>'status' = 'skipped' then
    update kut.midweek_tournaments set status = 'skipped', status_reason = v_result->>'reason', updated_at = now()
    where id = p_tournament_id;
    return 'skipped';
  end if;

  v_rounds := (v_result->>'rounds')::int;

  insert into kut.midweek_entries (tournament_id, user_id, auto, keeper_slot, keeperless)
  select p_tournament_id, (entry->>'userId')::uuid, (entry->>'auto')::boolean,
    (entry->>'keeperSlot')::smallint, (entry->>'keeperless')::boolean
  from jsonb_array_elements(v_result->'entries') entry;

  insert into kut.midweek_entry_cards (tournament_id, user_id, slot, trialist, card_id, player_id, ovr, archetype,
    injured, ovr_factor_ppm, form_roll_ppm, pick_factor_ppm, fitness_ppm, handicap_ppm, power_ppm,
    att_ppm, mid_ppm, def_ppm)
  select p_tournament_id, (entry->>'userId')::uuid, (card->>'slot')::smallint, (card->>'trialist')::boolean,
    (card->>'cardId')::uuid, (card->>'playerId')::uuid, (card->>'ovr')::smallint, card->>'archetype',
    (card->>'injured')::boolean, (card->>'ovrFactorPpm')::int, (card->>'formRollPpm')::int,
    (card->>'pickFactorPpm')::int, (card->>'fitnessPpm')::int, (card->>'handicapPpm')::int,
    (card->>'powerPpm')::int, (card#>>'{lines,attPpm}')::int, (card#>>'{lines,midPpm}')::int,
    (card#>>'{lines,defPpm}')::int
  from jsonb_array_elements(v_result->'entries') entry, jsonb_array_elements(entry->'cards') card;

  insert into kut.midweek_pick_shares (tournament_id, player_id, owners, picks, share_ppm, pick_factor_ppm)
  select p_tournament_id, (share->>'playerId')::uuid, (share->>'owners')::smallint, (share->>'picks')::smallint,
    (share->>'sharePpm')::int, (share->>'pickFactorPpm')::int
  from jsonb_array_elements(v_result->'pickShares') share;

  insert into kut.midweek_matches (tournament_id, round, pairing, bye, side_0_user_id, winner_side, winner_user_id,
    reveal_at, ends_at)
  select p_tournament_id, 1, (bye->>'pairing')::smallint, true, (bye->>'userId')::uuid, 0, (bye->>'userId')::uuid,
    clock.start_at, clock.start_at
  from jsonb_array_elements(v_result->'byes') bye
  cross join lateral (
    select kut._mm_round_start_at(v_tournament.lock_at, 1, v_tournament.schedule_version) as start_at
  ) clock;

  insert into kut.midweek_matches (tournament_id, round, pairing, bye, side_0_user_id, side_1_user_id,
    side_0_goals, side_1_goals, side_0_penalties, side_1_penalties, winner_side, winner_user_id,
    win_chance_ppm, side_0_day_rolls_ppm, side_1_day_rolls_ppm, reveal_at, ends_at)
  select p_tournament_id, (played->>'round')::smallint, (played->>'pairing')::smallint, false,
    (played#>>'{userIds,0}')::uuid, (played#>>'{userIds,1}')::uuid,
    (played#>>'{outcome,goals,0}')::smallint, (played#>>'{outcome,goals,1}')::smallint,
    (played#>>'{outcome,penalties,0}')::smallint, (played#>>'{outcome,penalties,1}')::smallint,
    (played#>>'{outcome,winnerSide}')::smallint,
    (played->'userIds'->>((played#>>'{outcome,winnerSide}')::int))::uuid,
    (played#>>'{outcome,winChancePpm}')::int,
    array(select jsonb_array_elements_text(played#>'{outcome,dayRollsPpm,0}')::int),
    array(select jsonb_array_elements_text(played#>'{outcome,dayRollsPpm,1}')::int),
    clock.start_at,
    clock.start_at + interval '1 millisecond' * (clock.timing->>'endOffsetMs')::bigint
  from jsonb_array_elements(v_result->'matches') played
  cross join lateral (
    select kut._mm_round_start_at(v_tournament.lock_at, (played->>'round')::int, v_tournament.schedule_version) as start_at,
      kut._mm_match_timing(played#>'{outcome,events}', v_tournament.schedule_version) as timing
  ) clock;

  insert into kut.midweek_match_events (match_id, seq, kind, side, minute, penalty_round, creator_slot, shooter_slot,
    defender_slot, kicker_slot, keeper_slot, chance_type, outcome, p_goal_ppm, reveal_at)
  select stored.id, (event.ord - 1)::smallint, event.value->>'kind', (event.value->>'side')::smallint,
    (event.value->>'minute')::smallint,
    case when event.value->>'kind' = 'penalty' then (event.value->>'round')::smallint end,
    (event.value->>'creator')::smallint, (event.value->>'shooter')::smallint,
    (event.value->>'defender')::smallint, (event.value->>'kicker')::smallint,
    case when event.value->>'kind' = 'penalty' then (event.value->>'keeper')::smallint end,
    event.value->>'chanceType', event.value->>'outcome', (event.value->>'pGoalPpm')::int,
    stored.reveal_at + interval '1 millisecond' * (clock.timing->'eventOffsetsMs'->>((event.ord - 1)::int))::bigint
  from jsonb_array_elements(v_result->'matches') played
  join kut.midweek_matches stored
    on stored.tournament_id = p_tournament_id
   and stored.round = (played->>'round')::int and stored.pairing = (played->>'pairing')::int
  cross join lateral (
    select kut._mm_match_timing(played#>'{outcome,events}', v_tournament.schedule_version) as timing
  ) clock
  cross join lateral jsonb_array_elements(played#>'{outcome,events}') with ordinality as event(value, ord);

  update kut.midweek_tournaments
  set status = 'simulated', rounds = v_rounds,
    final_reveal_at = (
      select max(final.ends_at) from kut.midweek_matches final
      where final.tournament_id = p_tournament_id and final.round = v_rounds),
    updated_at = now()
  where id = p_tournament_id;
  return 'simulated';
end $$;

-- As in 20261005000000_midweek_engine.sql section 4, naming the version the
-- new week follows.
create or replace function kut._mm_open_next()
returns uuid language plpgsql security definer set search_path = kut, pg_catalog as $$
declare v_week date; v_seed text; v_id uuid; v_version integer := (kut._mm_config()#>>'{schedule,current}')::int;
begin
  if not coalesce((select enabled from kut.midweek_config), false) then return null; end if;
  if exists (select 1 from kut.midweek_tournaments where status in ('open', 'simulated')) then return null; end if;

  v_week := kut._mm_next_week();
  -- 32 bytes from two version-4 UUIDs (pg_strong_random, 244 random bits),
  -- hashed so the seed carries no fixed version nibbles.
  v_seed := encode(sha256(convert_to(gen_random_uuid()::text || gen_random_uuid()::text, 'UTF8')), 'hex');
  insert into kut.midweek_tournaments (week_start, lock_at, seed_hash, schedule_version)
  values (v_week, kut._mm_lock_at(v_week, v_version), encode(sha256(decode(v_seed, 'hex')), 'hex'), v_version)
  on conflict (week_start) do nothing
  returning id into v_id;
  if v_id is not null then
    insert into kut.midweek_tournament_secrets (tournament_id, seed) values (v_id, v_seed);
  end if;
  return v_id;
end $$;

-- 6. The rehearsal ------------------------------------------------------------------
-- As in 20261005000000_midweek_engine.sql section 6, on the open week's clock
-- (or the current one with no week open): each round's start and the moment
-- its last match ends, and the version, appended.
create or replace function kut.admin_midweek_rehearsal()
returns jsonb language plpgsql security definer set search_path = kut, pg_catalog as $$
declare
  v_tournament kut.midweek_tournaments%rowtype;
  v_week date; v_lock timestamptz; v_field jsonb; v_result jsonb; v_names jsonb; v_seed text;
  v_warnings jsonb; v_would_skip text; v_count integer; v_version integer;
begin
  if not kut.is_admin() then raise exception 'admin role required' using errcode = '42501'; end if;

  select * into v_tournament from kut.midweek_tournaments where status = 'open' order by week_start limit 1;
  v_version := coalesce(v_tournament.schedule_version, (kut._mm_config()#>>'{schedule,current}')::int);
  v_week := coalesce(v_tournament.week_start, kut._mm_next_week());
  v_lock := coalesce(v_tournament.lock_at, kut._mm_lock_at(v_week, v_version));
  v_field := kut._mm_field(v_tournament.id, now());
  v_count := jsonb_array_length(v_field->'entrants');
  v_seed := encode(sha256(convert_to(gen_random_uuid()::text || gen_random_uuid()::text, 'UTF8')), 'hex');
  v_result := kut._mm_simulate(decode(v_seed, 'hex'), v_field->'entrants');

  select coalesce(jsonb_object_agg(profile.id, profile.display_name), '{}'::jsonb) into v_names
  from kut.profiles profile
  where profile.id in (select (entrant->>'userId')::uuid from jsonb_array_elements(v_field->'entrants') entrant);

  v_warnings := v_field->'warnings';
  if not kut._mm_club_played(v_week) then
    v_would_skip := 'club_break';
    v_warnings := jsonb_build_array(jsonb_build_object('level', 'warning', 'message',
      'The football week before ' || to_char(v_week, 'YYYY-MM-DD') || ' has no published session yet: at the lock the week would be skipped as a club break.'))
      || v_warnings;
  elsif v_result->>'status' = 'skipped' then
    v_would_skip := 'too_few_entrants';
  end if;
  if v_result->>'status' = 'skipped' then
    v_warnings := jsonb_build_array(jsonb_build_object('level', 'warning', 'message',
      format('Only %s members would enter; a week needs %s.', v_count, kut._mm_config()->>'minEntrants')))
      || v_warnings;
  end if;
  if v_tournament.id is null then
    v_warnings := v_warnings || jsonb_build_array(jsonb_build_object('level', 'info', 'message',
      'No tournament is open, so nobody has saved a squad: every entrant plays an auto squad.'));
  end if;
  if not coalesce((select enabled from kut.midweek_config), false) then
    v_warnings := v_warnings || jsonb_build_array(jsonb_build_object('level', 'info', 'message',
      'Midweek Madness is paused: no new tournament opens until it is switched on.'));
  end if;

  return jsonb_build_object(
    'ran_at', now(),
    'tournament_id', v_tournament.id,
    'week_start', v_week,
    'lock_at', v_lock,
    'status', v_result->>'status',
    'would_skip', v_would_skip,
    'field', v_count,
    'picked', (select count(*) from jsonb_array_elements(v_field->'entrants') e where jsonb_array_length(e->'saved') > 0),
    'auto', (select count(*) from jsonb_array_elements(v_field->'entrants') e where jsonb_array_length(e->'saved') = 0),
    'opted_out', (select count(*) from kut.midweek_opt_outs),
    'auto_managers', (
      select coalesce(jsonb_agg(v_names->>(e->>'userId') order by v_names->>(e->>'userId')), '[]'::jsonb)
      from jsonb_array_elements(v_field->'entrants') e where jsonb_array_length(e->'saved') = 0),
    'size', v_result->'size',
    'rounds', v_result->'rounds',
    'by_round', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'round', round_no,
        'reveal_at', kut._mm_round_start_at(v_lock, round_no, v_version),
        'pairings', (
          select coalesce(jsonb_agg(pairing order by (pairing->>'pairing')::int), '[]'::jsonb)
          from (
            select jsonb_build_object('pairing', (bye->>'pairing')::int, 'bye', true,
              'side_0', v_names->>(bye->>'userId'), 'side_1', null, 'goals', null, 'penalties', null,
              'winner', v_names->>(bye->>'userId')) as pairing
            from jsonb_array_elements(v_result->'byes') bye
            where round_no = 1
            union all
            select jsonb_build_object('pairing', (played->>'pairing')::int, 'bye', false,
              'side_0', v_names->>(played#>>'{userIds,0}'), 'side_1', v_names->>(played#>>'{userIds,1}'),
              'goals', played#>'{outcome,goals}', 'penalties', played#>'{outcome,penalties}',
              'winner', v_names->>(played->'userIds'->>((played#>>'{outcome,winnerSide}')::int)))
            from jsonb_array_elements(v_result->'matches') played
            where (played->>'round')::int = round_no
          ) pairings),
        'ends_at', kut._mm_round_start_at(v_lock, round_no, v_version) + interval '1 millisecond' * coalesce((
          select max((kut._mm_match_timing(played#>'{outcome,events}', v_version)->>'endOffsetMs')::bigint)
          from jsonb_array_elements(v_result->'matches') played
          where (played->>'round')::int = round_no), 0)
      ) order by round_no), '[]'::jsonb)
      from generate_series(1, coalesce((v_result->>'rounds')::int, 0)) round_no),
    'champion', case when v_result->>'status' = 'simulated' then jsonb_build_object(
      'user_id', v_result->'championUserId', 'name', v_names->>(v_result->>'championUserId')) end,
    'warnings', v_warnings,
    'schedule_version', v_version);
end $$;

-- 7. Projections: the version, appended ------------------------------------------------

-- As in 20261003000000_midweek_entry.sql section 3, with schedule_version last
-- (null while no tournament exists).
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
    tournament.final_reveal_at,
    tournament.seed,
    exists (select 1 from kut.midweek_opt_outs o where o.user_id = auth.uid()) as opted_out,
    tournament.schedule_version
  from kut.midweek_config config
  left join lateral (
    select * from kut.midweek_tournaments order by week_start desc limit 1
  ) tournament on true
) gated
where kut.is_active_member();

comment on view kut.midweek_current is
  'ADR-089, ADR-104: the Midweek Madness launch switch, the latest tournament (seed hash from creation, seed only once complete, the version of its clock) and the caller''s opt-out. Gated on kut.is_active_member() (ADR-079).';

-- As in 20261005000000_midweek_engine.sql section 5, with schedule_version last.
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
  tournament.final_reveal_at,
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
  'ADR-089, ADR-095, ADR-104: every Midweek Madness tournament (status, skip or void reason, reveal times, the seed only once complete, the version of its clock) and its champion once the final is revealed. Gated on kut.is_active_member() (ADR-079).';

-- 8. The open week moves to the new clock ----------------------------------------------
-- An open week's lock may still move (Part L #25). Only if 19:55 is still
-- ahead: a push between 19:55 and the lock leaves that week on version 1.
update kut.midweek_tournaments
set schedule_version = 2, lock_at = kut._mm_lock_at(week_start, 2), updated_at = now()
where status = 'open' and schedule_version = 1 and kut._mm_lock_at(week_start, 2) > now();

alter table kut.midweek_tournaments alter column schedule_version set default 2;

-- Every engine and internal function stays out of members' reach, the new
-- ones included.
do $$ declare v_fn regprocedure; begin
  for v_fn in
    select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'kut' and p.proname like '\_mm\_%'
  loop
    execute format('revoke all on function %s from public, anon, authenticated', v_fn);
  end loop;
end $$;
