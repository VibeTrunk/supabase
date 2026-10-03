-- Midweek Madness 2.0, C2: balanced squads beat All-rounders (BUILD_SPEC
-- §44.3, §44.4, §44.5, §44.12, §44.14, §145; ADR-116, amending ADR-089 and
-- ADR-092).
--
-- Each archetype's plusses per line (attack, midfield, defence, 0-3) become
-- the engine's input in place of the §15.1 offsets: the table members see is
-- the table the engine reads. The All-rounder has one plus in every line and
-- every other archetype four. The four outfielders' plusses are added up per
-- line, and every plus a line falls short of three multiplies the whole squad
-- by 0.88 (the weakest-line rule). Outfield defence now counts 0.8 of a shot's
-- resistance (it was half), a Goalkeeper in goal keeps its strength (1.65), and
-- a stand-in keeper is 0.45 of that whatever its archetype. Retuned with the
-- weekly rotation on: OVR factor at 83 1.10 -> 1.12, auto factor 0.575 -> 0.55.
-- Evidence: docs/archive/MIDWEEK_TUNING.md, signed off by the owner 2026-10-03.
--
--   1. kut._mm_config()                -- `shape` becomes {plusses, attPpm,
--                                         midPpm, defPpm}; new `balance`,
--                                         `keeperPpm`, match.defenceWeightPpm;
--                                         the retuned values (parity test).
--   2. kut._mm_lines                   -- reads the plusses, not the offsets.
--   3. kut._mm_balance                 -- new: shape.ts `squadBalance`.
--   4. kut._mm_play_match              -- the balance on every card's power,
--                                         the keeper's own strength, the
--                                         defence weight.
--   5. kut._mm_simulate                -- each entry carries its balancePpm.
--   6. kut.midweek_entries.balance_ppm -- written by the lock step; null on
--                                         every week locked before this push,
--                                         which played without the rule.
--   7. kut._mm_lock_tournament         -- stores it.
--   8. kut.midweek_entries_public      -- appends balance_ppm.
--
-- The engine is a pure function of the locked squads and the seed (Part L
-- #25): a week already simulated keeps its stored result and is never re-run.
-- The week open at the push locks on the new rules (owner, 2026-10-03: switch
-- at the push). No invariant changes; golden vectors and the parity test are
-- regenerated (ADR-090).
--
-- Deploy ordering: Vercel deploys on merge, before this push. The pages read
-- midweek_entries_public with select("*") and treat a missing or null
-- balance_ppm as "no balance factor", which is what every hosted week is
-- until a week locks on this engine.
--
-- Tier: data-changing (docs/OPERATIONS.md): it changes what the lock step
-- computes and so who is paid. Fresh cold-verified backup first.
--
-- Rollback (before a week locks on the new engine; after that, the stored
-- results stay as they are and only the next lock changes):
--   re-create kut.midweek_entries_public from 20261012000000_midweek_draw_from_lock.sql
--     (drop it first: a view cannot lose columns);
--   re-create kut._mm_lock_tournament and kut._mm_config from
--     20261011000000_midweek_evening_timing.sql;
--   re-create kut._mm_lines, kut._mm_play_match and kut._mm_simulate from
--     20261005000000_midweek_engine.sql;
--   drop function kut._mm_balance(text[], integer);
--   alter table kut.midweek_entries drop column balance_ppm;

-- 1. The configuration -------------------------------------------------------------
-- Verbatim from MIDWEEK in src/game/midweek/config.ts; the parity test compares
-- it with tests/fixtures/midweek-golden.json key for key.
create or replace function kut._mm_config()
returns jsonb language sql immutable parallel safe set search_path = kut, pg_catalog as $$
  select '{"squadSize":5,"minEntrants":4,"championTotal":250,"ownerCountMin":3,"schedule":{"lockDayOffset":2,"current":2,"versions":{"1":{"lockHourLocal":20,"lockMinuteLocal":0,"roundOffsetMinutes":30,"roundIntervalMinutes":30,"slotSeconds":0,"kickSeconds":0},"2":{"lockHourLocal":19,"lockMinuteLocal":55,"roundOffsetMinutes":5,"roundIntervalMinutes":15,"slotSeconds":20,"kickSeconds":5}}},"ovr":{"min":30,"max":83,"factorMaxPpm":1120000},"form":{"minPpm":800000,"modePpm":1000000,"maxPpm":1250000,"dice":2},"pick":{"points":[[0,1250000],[400000,1000000],[1000000,875000]],"smoothingPicks":1,"smoothingOwners":3,"neutralPpm":1000000},"dayRollSpreadPpm":120000,"injuredFitnessPpm":950000,"autoFactorPpm":550000,"trialist":{"ovr":30,"factorPpm":825000},"shape":{"plusses":{"all_rounder":[1,1,1],"speedster":[2,2,0],"finisher":[3,1,0],"playmaker":[1,3,0],"defender":[0,1,3],"tank":[0,2,2],"goalkeeper":[0,0,3]},"attPpm":[500000,1000000,1500000,2000000],"midPpm":[500000,1000000,1500000,2000000],"defPpm":[200000,1000000,1800000,2600000]},"balance":{"minPlusses":3,"shortfallPpm":880000},"keeperPpm":1650000,"keeperlessFactorPpm":450000,"keeperCreatorWeightPpm":150000,"keeperShooterWeightPpm":5000,"match":{"intendedGoalsPerMatch":2.5,"chanceSlots":14,"chanceRatePpm":686000,"midfieldContrast":1,"goalBasePpm":300000,"defenceWeightPpm":800000,"finishingContrast":1,"goalMinPpm":20000,"goalMaxPpm":850000,"minutes":90,"missWeights":{"save":45,"block":25,"woodwork":8,"wide":22}},"penalties":{"kicks":5,"basePpm":750000,"contrast":1,"minPpm":400000,"maxPpm":950000,"maxSuddenDeathRounds":20,"missWeights":{"save":60,"woodwork":15,"wide":25}},"winChanceContrast":3,"chanceTypes":{"solo":["breakaway","wing_run","long_shot","curler","scramble","free_kick"],"base":{"breakaway":3,"wing_run":3,"chase":2,"volley":2,"first_time":4,"overhead":0,"through_ball":4,"free_kick":2,"curler":3,"header":3,"scramble":4,"long_shot":3,"long_throw":0,"cutback":5,"one_two":4},"creatorBonus":{"all_rounder":{},"speedster":{"wing_run":5,"cutback":3},"finisher":{"one_two":2},"playmaker":{"through_ball":6,"free_kick":3,"one_two":3},"defender":{"header":2,"scramble":2},"tank":{"header":2,"scramble":2},"goalkeeper":{"long_throw":8,"breakaway":3}},"shooterBonus":{"all_rounder":{},"speedster":{"breakaway":6,"chase":6,"wing_run":2},"finisher":{"volley":5,"first_time":6,"overhead":1},"playmaker":{"curler":5,"free_kick":4},"defender":{"header":6,"scramble":4,"long_shot":3},"tank":{"header":6,"scramble":4,"long_shot":4},"goalkeeper":{"long_shot":2}},"difficultyPpm":{"breakaway":1200000,"wing_run":850000,"chase":1000000,"volley":800000,"first_time":1000000,"overhead":400000,"through_ball":1100000,"free_kick":550000,"curler":700000,"header":900000,"scramble":1150000,"long_shot":450000,"long_throw":900000,"cutback":1250000,"one_two":1100000}}}'::jsonb
$$;

-- 2. Lines from the plusses ---------------------------------------------------------
-- shape.ts `lineMultsPpm`: each line's value for the archetype's plusses in it.
create or replace function kut._mm_lines(p_archetype text, out att_ppm bigint, out mid_ppm bigint, out def_ppm bigint)
language plpgsql immutable parallel safe set search_path = kut, pg_catalog as $$
declare
  c jsonb := kut._mm_config()->'shape';
  p jsonb := c->'plusses'->p_archetype;
begin
  if p is null then raise exception 'unknown archetype %', p_archetype using errcode = '22023'; end if;
  att_ppm := (c->'attPpm'->>((p->>0)::int))::bigint;
  mid_ppm := (c->'midPpm'->>((p->>1)::int))::bigint;
  def_ppm := (c->'defPpm'->>((p->>2)::int))::bigint;
end $$;

-- 3. The weakest-line rule ---------------------------------------------------------
-- shape.ts `squadBalance`: the outfielders' plusses per line (the keeper's slot
-- skipped), how far each falls short of balance.minPlusses, and the squad
-- factor, shortfallPpm once per plus short, floored after each step.
create function kut._mm_balance(p_archetypes text[], p_keeper_slot integer)
returns jsonb language plpgsql immutable parallel safe set search_path = kut, pg_catalog as $$
declare
  c jsonb := kut._mm_config();
  v_min integer := (c#>>'{balance,minPlusses}')::int;
  v_factor bigint := (c#>>'{balance,shortfallPpm}')::bigint;
  v_lines integer[] := array[0, 0, 0];
  v_short integer[];
  v_balance bigint := 1000000;
  v_plusses jsonb; v_slot integer; v_line integer;
begin
  for v_slot in 0 .. coalesce(cardinality(p_archetypes), 0) - 1 loop
    continue when v_slot = p_keeper_slot;
    v_plusses := c#>array['shape', 'plusses', p_archetypes[v_slot + 1]];
    if v_plusses is null then
      raise exception 'unknown archetype %', p_archetypes[v_slot + 1] using errcode = '22023';
    end if;
    for v_line in 0 .. 2 loop
      v_lines[v_line + 1] := v_lines[v_line + 1] + (v_plusses->>v_line)::int;
    end loop;
  end loop;
  v_short := array[greatest(0, v_min - v_lines[1]), greatest(0, v_min - v_lines[2]), greatest(0, v_min - v_lines[3])];
  for v_line in 1 .. v_short[1] + v_short[2] + v_short[3] loop
    v_balance := kut._mm_mul(v_balance, v_factor);
  end loop;
  return jsonb_build_object('lines', to_jsonb(v_lines), 'short', to_jsonb(v_short), 'balancePpm', v_balance);
end $$;

-- 4. A match ------------------------------------------------------------------------
-- As in 20261005000000_midweek_engine.sql section 1, except: every card's power is
-- multiplied by its side's balancePpm before its lines, a keeper's strength is
-- keeperPpm (times the keeperless factor for a stand-in) instead of its defence
-- line, and a shot's resistance weighs outfield defence by match.defenceWeightPpm.
create or replace function kut._mm_play_match(p_seed bytea, p_prefix text, p_a jsonb, p_b jsonb)
returns jsonb language plpgsql immutable parallel safe set search_path = kut, pg_catalog as $$
declare
  c jsonb := kut._mm_config();
  m jsonb := c->'match';
  pen jsonb := c->'penalties';
  v_types text[] := kut._mm_chance_types();
  v_sides jsonb[] := array[p_a, p_b];
  v_n integer[] := array[jsonb_array_length(p_a->'cards'), jsonb_array_length(p_b->'cards')];
  v_base integer[] := array[0, jsonb_array_length(p_a->'cards')];
  v_keeper integer[] := array[(p_a->>'keeperSlot')::int, (p_b->>'keeperSlot')::int];
  v_keeperless boolean[] := array[(p_a->>'keeperless')::boolean, (p_b->>'keeperless')::boolean];
  v_keeperless_factor bigint := (c->>'keeperlessFactorPpm')::bigint;
  v_keeper_ppm bigint := (c->>'keeperPpm')::bigint;
  v_defence_weight bigint := (m->>'defenceWeightPpm')::bigint;
  v_balance bigint[] := array[(p_a->>'balancePpm')::bigint, (p_b->>'balancePpm')::bigint];
  v_rated bigint;
  v_arch text[] := '{}';
  v_day bigint[] := '{}';
  v_att bigint[] := '{}'; v_mid bigint[] := '{}'; v_def bigint[] := '{}';
  v_keeper_strength bigint[] := array[0, 0]::bigint[];
  v_mid_total bigint[] := array[0, 0]::bigint[];
  v_def_total bigint[] := array[0, 0]::bigint[];
  v_rating bigint[] := array[0, 0]::bigint[];
  v_goals integer[] := array[0, 0];
  v_events jsonb := '[]'::jsonb;
  v_card jsonb; v_week bigint; v_power bigint; v_attm bigint; v_midm bigint; v_defm bigint;
  v_s integer; v_i integer; v_idx integer; v_slot integer; v_tag text;
  v_side integer; v_opp integer; v_mid_share bigint;
  v_weights bigint[]; v_creator integer; v_shooter integer; v_type text;
  v_resistance bigint; v_finishing bigint; v_p_goal bigint; v_outcome text; v_defender integer;
  v_low integer; v_high integer; v_minute integer;
  v_winner integer; v_penalties jsonb := 'null'::jsonb;
  v_order integer[] := '{}'; v_kick_order integer[]; v_score integer[] := array[0, 0];
  v_taken integer[] := array[0, 0]; v_round integer; v_k integer; v_kicker integer; v_done boolean := false;
  v_kicks integer := (pen->>'kicks')::int;
  v_misses text[];
begin
  -- Per-card lines, week-long ratings (no day roll) and this match's contributions.
  for v_s in 0 .. 1 loop
    for v_i in 0 .. v_n[v_s + 1] - 1 loop
      v_card := v_sides[v_s + 1]->'cards'->v_i;
      v_week := (v_card->>'weekPowerPpm')::bigint;
      v_attm := (v_card#>>'{lines,attPpm}')::bigint;
      v_midm := (v_card#>>'{lines,midPpm}')::bigint;
      v_defm := (v_card#>>'{lines,defPpm}')::bigint;
      v_arch := v_arch || (v_card->>'archetype');

      -- sideRatingPpm, from the week-long power times the squad's balance.
      v_rated := kut._mm_mul(v_week, v_balance[v_s + 1]);
      if v_i = v_keeper[v_s + 1] then
        v_rating[v_s + 1] := v_rating[v_s + 1] + case when v_keeperless[v_s + 1]
          then kut._mm_mul(kut._mm_mul(v_rated, v_keeper_ppm), v_keeperless_factor) else kut._mm_mul(v_rated, v_keeper_ppm) end;
      else
        v_rating[v_s + 1] := v_rating[v_s + 1] + kut._mm_mul(v_rated, v_attm) + kut._mm_mul(v_rated, v_midm)
          + kut._mm_mul(v_rated, v_defm);
      end if;

      v_day := v_day || kut._mm_day_roll(p_seed, p_prefix || ':day:' || v_s || ':' || v_i);
      v_power := kut._mm_mul(kut._mm_mul(v_week, v_day[v_base[v_s + 1] + v_i + 1]), v_balance[v_s + 1]);
      v_att := v_att || kut._mm_mul(v_power, v_attm);
      v_mid := v_mid || kut._mm_mul(v_power, v_midm);
      v_def := v_def || kut._mm_mul(v_power, v_defm);
      if v_i = v_keeper[v_s + 1] then
        v_keeper_strength[v_s + 1] := case when v_keeperless[v_s + 1]
          then kut._mm_mul(kut._mm_mul(v_power, v_keeper_ppm), v_keeperless_factor) else kut._mm_mul(v_power, v_keeper_ppm) end;
      else
        v_mid_total[v_s + 1] := v_mid_total[v_s + 1] + kut._mm_mul(v_power, v_midm);
        v_def_total[v_s + 1] := v_def_total[v_s + 1] + kut._mm_mul(v_power, v_defm);
      end if;
    end loop;
  end loop;

  v_mid_share := kut._mm_power_share(v_mid_total[1], v_mid_total[2], (m->>'midfieldContrast')::int);

  for v_slot in 0 .. (m->>'chanceSlots')::int - 1 loop
    v_tag := p_prefix || ':c:' || v_slot;
    continue when kut._mm_uniform(p_seed, v_tag || ':occ', 1000000) >= (m->>'chanceRatePpm')::bigint;

    v_side := case when kut._mm_uniform(p_seed, v_tag || ':side', 1000000) < v_mid_share then 0 else 1 end;
    v_opp := 1 - v_side;

    v_weights := '{}';
    for v_i in 0 .. v_n[v_side + 1] - 1 loop
      v_idx := v_base[v_side + 1] + v_i + 1;
      v_weights := v_weights || case when v_i = v_keeper[v_side + 1]
        then kut._mm_mul(v_mid[v_idx], (c->>'keeperCreatorWeightPpm')::bigint) else v_mid[v_idx] end;
    end loop;
    v_creator := kut._mm_pick_weighted(p_seed, v_tag || ':creator', v_weights);

    v_weights := '{}';
    for v_i in 0 .. v_n[v_side + 1] - 1 loop
      v_idx := v_base[v_side + 1] + v_i + 1;
      v_weights := v_weights || case when v_i = v_keeper[v_side + 1]
        then kut._mm_mul(v_att[v_idx], (c->>'keeperShooterWeightPpm')::bigint) else v_att[v_idx] end;
    end loop;
    v_shooter := kut._mm_pick_weighted(p_seed, v_tag || ':shooter', v_weights);

    v_type := v_types[1 + kut._mm_pick_weighted(p_seed, v_tag || ':type', kut._mm_chance_type_weights(
      v_arch[v_base[v_side + 1] + v_creator + 1], v_arch[v_base[v_side + 1] + v_shooter + 1], v_creator = v_shooter))];

    v_resistance := kut._mm_mul(v_def_total[v_opp + 1] / (v_n[v_opp + 1] - 1), v_defence_weight)
      + kut._mm_mul(v_keeper_strength[v_opp + 1], 1000000 - v_defence_weight);
    v_finishing := 2 * kut._mm_power_share(v_att[v_base[v_side + 1] + v_shooter + 1], v_resistance,
      (m->>'finishingContrast')::int);
    v_p_goal := least(greatest(
      kut._mm_mul(kut._mm_mul((m->>'goalBasePpm')::bigint, (c#>>array['chanceTypes', 'difficultyPpm', v_type])::bigint), v_finishing),
      (m->>'goalMinPpm')::bigint), (m->>'goalMaxPpm')::bigint);

    v_outcome := 'goal';
    v_defender := null;
    if kut._mm_uniform(p_seed, v_tag || ':goal', 1000000) < v_p_goal then
      v_goals[v_side + 1] := v_goals[v_side + 1] + 1;
    else
      v_misses := array['save', 'block', 'woodwork', 'wide'];
      v_outcome := v_misses[1 + kut._mm_pick_weighted(p_seed, v_tag || ':miss', array[
        (m#>>'{missWeights,save}')::bigint, (m#>>'{missWeights,block}')::bigint,
        (m#>>'{missWeights,woodwork}')::bigint, (m#>>'{missWeights,wide}')::bigint])];
      if v_outcome = 'save' then
        v_defender := v_keeper[v_opp + 1];
      elsif v_outcome in ('block', 'wide') then
        v_weights := '{}';
        for v_i in 0 .. v_n[v_opp + 1] - 1 loop
          v_weights := v_weights || case when v_i = v_keeper[v_opp + 1] then 0::bigint
            else v_def[v_base[v_opp + 1] + v_i + 1] end;
        end loop;
        v_defender := kut._mm_pick_weighted(p_seed, v_tag || ':defender', v_weights);
      end if;
    end if;

    v_low := v_slot * (m->>'minutes')::int / (m->>'chanceSlots')::int + 1;
    v_high := (v_slot + 1) * (m->>'minutes')::int / (m->>'chanceSlots')::int;
    v_minute := v_low + kut._mm_uniform(p_seed, v_tag || ':minute', v_high - v_low + 1);

    v_events := v_events || jsonb_build_array(jsonb_build_object(
      'kind', 'chance', 'minute', v_minute, 'side', v_side, 'creator', v_creator, 'shooter', v_shooter,
      'chanceType', v_type, 'outcome', v_outcome, 'pGoalPpm', v_p_goal, 'defender', v_defender));
  end loop;

  if v_goals[1] <> v_goals[2] then
    v_winner := case when v_goals[1] > v_goals[2] then 0 else 1 end;
  else
    -- playShootout. Each side kicks in order of outfield attack (strongest
    -- first, lower slot on a tie), then its keeper, then round again.
    for v_s in 0 .. 1 loop
      select v_order || array_agg(i order by v_att[v_base[v_s + 1] + i + 1] desc, i) || v_keeper[v_s + 1]
      into v_order
      from generate_series(0, v_n[v_s + 1] - 1) i
      where i <> v_keeper[v_s + 1];
    end loop;
    v_kick_order := case when kut._mm_uniform(p_seed, p_prefix || ':p:first', 2) = 0
      then array[0, 1] else array[1, 0] end;
    v_misses := array['save', 'woodwork', 'wide'];
    v_round := 1;
    while not v_done and v_round <= v_kicks + (pen->>'maxSuddenDeathRounds')::int loop
      foreach v_side in array v_kick_order loop
        v_opp := 1 - v_side;
        v_kicker := v_order[v_base[v_side + 1] + (v_round - 1) % v_n[v_side + 1] + 1];
        v_tag := p_prefix || ':p:' || v_round || ':' || v_side;
        v_p_goal := least(greatest(
          kut._mm_mul((pen->>'basePpm')::bigint, 2 * kut._mm_power_share(v_att[v_base[v_side + 1] + v_kicker + 1],
            v_keeper_strength[v_opp + 1], (pen->>'contrast')::int)),
          (pen->>'minPpm')::bigint), (pen->>'maxPpm')::bigint);
        v_outcome := 'goal';
        if kut._mm_uniform(p_seed, v_tag || ':goal', 1000000) < v_p_goal then
          v_score[v_side + 1] := v_score[v_side + 1] + 1;
        else
          v_outcome := v_misses[1 + kut._mm_pick_weighted(p_seed, v_tag || ':miss', array[
            (pen#>>'{missWeights,save}')::bigint, (pen#>>'{missWeights,woodwork}')::bigint,
            (pen#>>'{missWeights,wide}')::bigint])];
        end if;
        v_taken[v_side + 1] := v_taken[v_side + 1] + 1;
        v_events := v_events || jsonb_build_array(jsonb_build_object(
          'kind', 'penalty', 'round', v_round, 'side', v_side, 'kicker', v_kicker, 'keeper', v_keeper[v_opp + 1],
          'outcome', v_outcome, 'pGoalPpm', v_p_goal));
        -- In the first five rounds, stop as soon as one side cannot be caught.
        if v_round <= v_kicks and (
          v_score[1] + (v_kicks - v_taken[1]) < v_score[2] or v_score[2] + (v_kicks - v_taken[2]) < v_score[1]
        ) then
          v_done := true;
          exit;
        end if;
      end loop;
      if not v_done and v_round >= v_kicks and v_score[1] <> v_score[2] then v_done := true; end if;
      v_round := v_round + 1;
    end loop;

    if v_done then
      v_winner := case when v_score[1] > v_score[2] then 0 else 1 end;
    else
      v_winner := case when kut._mm_uniform(p_seed, p_prefix || ':p:toss', 2) = 0 then 0 else 1 end;
      v_events := v_events || jsonb_build_array(jsonb_build_object('kind', 'toss', 'side', v_winner));
    end if;
    v_penalties := jsonb_build_array(v_score[1], v_score[2]);
  end if;

  return jsonb_build_object(
    'goals', jsonb_build_array(v_goals[1], v_goals[2]),
    'penalties', v_penalties,
    'winnerSide', v_winner,
    'winChancePpm', kut._mm_power_share(v_rating[1], v_rating[2], (c->>'winChanceContrast')::int),
    'dayRollsPpm', jsonb_build_array(to_jsonb(v_day[1 : v_n[1]]), to_jsonb(v_day[v_n[1] + 1 : v_n[1] + v_n[2]])),
    'events', v_events);
end $$;

-- 5. The tournament -----------------------------------------------------------------
-- As in 20261005000000_midweek_engine.sql section 1, except that each entry and
-- each side carries the squad's balancePpm.
create or replace function kut._mm_simulate(p_seed bytea, p_entrants jsonb)
returns jsonb language plpgsql immutable parallel safe set search_path = kut, pg_catalog as $$
declare
  c jsonb := kut._mm_config();
  v_size_cap integer := (c->>'squadSize')::int;
  v_ppm constant bigint := 1000000;
  v_count integer := coalesce(jsonb_array_length(p_entrants), 0);
  v_entrants jsonb; v_entrant jsonb; v_user text; v_auto boolean; v_cards jsonb; v_card jsonb;
  v_squads jsonb := '[]'::jsonb; v_squad jsonb;
  v_pick_shares jsonb; v_share_factor jsonb;
  v_entries jsonb := '[]'::jsonb; v_entry_cards jsonb; v_sides jsonb := '{}'::jsonb;
  v_slot integer; v_handicap bigint; v_ovr_factor bigint; v_form bigint; v_pick bigint; v_fitness bigint;
  v_power bigint; v_lines record; v_archetype text;
  v_keeper integer; v_keeper_score bigint; v_keeperless boolean; v_score bigint; v_balance bigint;
  v_users text[]; v_size integer := 1; v_rounds integer := 0; v_pairing_count integer; v_bye_count integer;
  v_bye_pairings integer[]; v_seat_order integer[]; v_seated text[];
  v_first text[] := '{}'; v_second text[] := '{}'; v_next integer; v_pairing integer;
  v_pays integer[]; v_round integer; v_winners text[];
  v_byes jsonb := '[]'::jsonb; v_matches jsonb := '[]'::jsonb; v_payouts jsonb := '[]'::jsonb;
  v_outcome jsonb; v_winner text;
begin
  if v_count < (c->>'minEntrants')::int then
    return jsonb_build_object('status', 'skipped', 'reason', 'too_few_entrants');
  end if;

  -- tournament.ts `validate`: the caller has applied the lock-time checks.
  if (select count(distinct e->>'userId') from jsonb_array_elements(p_entrants) e) <> v_count then
    raise exception 'Duplicate Midweek entrant' using errcode = '22023';
  end if;
  if exists (
    select 1 from jsonb_array_elements(p_entrants) e
    where coalesce(jsonb_array_length(e->'owned'), 0) = 0
      or coalesce(jsonb_array_length(e->'saved'), 0) > v_size_cap
      or exists (
        select 1 from jsonb_array_elements(e->'saved') saved
        where not exists (
          select 1 from jsonb_array_elements(e->'owned') owned where owned->>'cardId' = saved->>'cardId'))
      or (select count(distinct saved->>'playerId') from jsonb_array_elements(e->'saved') saved)
        <> coalesce(jsonb_array_length(e->'saved'), 0)
  ) then
    raise exception 'Invalid Midweek field: an entrant owns no card, or a saved squad is invalid' using errcode = '22023';
  end if;

  select jsonb_agg(e order by e->>'userId' collate "C") into v_entrants from jsonb_array_elements(p_entrants) e;

  for v_entrant in select value from jsonb_array_elements(v_entrants) loop
    v_auto := jsonb_array_length(v_entrant->'saved') = 0;
    v_squads := v_squads || jsonb_build_array(jsonb_build_object(
      'userId', v_entrant->>'userId', 'auto', v_auto,
      'cards', case when v_auto then kut._mm_auto_squad(p_seed, v_entrant) else v_entrant->'saved' end));
  end loop;

  -- Pick shares: owners count every entrant owning the Player, picks only
  -- non-auto squads.
  with owners as (
    select owned->>'playerId' as player_id, count(distinct e->>'userId')::int as owners
    from jsonb_array_elements(v_entrants) e, jsonb_array_elements(e->'owned') owned
    group by 1
  ),
  picks as (
    select card->>'playerId' as player_id, count(*)::int as picks
    from jsonb_array_elements(v_squads) squad, jsonb_array_elements(squad->'cards') card
    where not (squad->>'auto')::boolean
    group by 1
  ),
  shares as (
    select owners.player_id, owners.owners, coalesce(picks.picks, 0) as picks,
      kut._mm_pick_share(coalesce(picks.picks, 0), owners.owners) as share_ppm
    from owners left join picks using (player_id)
  )
  select
    coalesce(jsonb_agg(jsonb_build_object('playerId', player_id, 'owners', owners, 'picks', picks,
      'sharePpm', share_ppm, 'pickFactorPpm', kut._mm_pick_factor(share_ppm)) order by player_id collate "C"), '[]'::jsonb),
    coalesce(jsonb_object_agg(player_id, kut._mm_pick_factor(share_ppm)), '{}'::jsonb)
  into v_pick_shares, v_share_factor
  from shares;

  -- Every card's week-long factors, trialists in the empty slots, and the keeper.
  for v_squad in select value from jsonb_array_elements(v_squads) loop
    v_user := v_squad->>'userId';
    v_auto := (v_squad->>'auto')::boolean;
    v_handicap := case when v_auto then (c->>'autoFactorPpm')::bigint else v_ppm end;
    v_entry_cards := '[]'::jsonb;
    for v_slot in 0 .. v_size_cap - 1 loop
      v_card := v_squad->'cards'->v_slot;
      if v_card is not null then
        v_archetype := v_card->>'archetype';
        v_ovr_factor := kut._mm_ovr_factor((v_card->>'ovr')::int);
        v_form := kut._mm_form_roll(p_seed, 'form:p:' || (v_card->>'playerId'));
        v_pick := case when v_auto then (c#>>'{pick,neutralPpm}')::bigint
          else (v_share_factor->>(v_card->>'playerId'))::bigint end;
        v_fitness := case when (v_card->>'injured')::boolean then (c->>'injuredFitnessPpm')::bigint else v_ppm end;
        v_power := kut._mm_card_power(v_ovr_factor, v_form, v_pick, v_fitness, v_handicap);
        select * into v_lines from kut._mm_lines(v_archetype);
        v_entry_cards := v_entry_cards || jsonb_build_array(jsonb_build_object(
          'slot', v_slot, 'cardId', v_card->'cardId', 'playerId', v_card->'playerId', 'trialist', false,
          'ovr', v_card->'ovr', 'archetype', v_archetype, 'injured', v_card->'injured',
          'ovrFactorPpm', v_ovr_factor, 'formRollPpm', v_form, 'pickFactorPpm', v_pick,
          'fitnessPpm', v_fitness, 'handicapPpm', v_handicap, 'powerPpm', v_power,
          'lines', jsonb_build_object('attPpm', v_lines.att_ppm, 'midPpm', v_lines.mid_ppm, 'defPpm', v_lines.def_ppm)));
      else
        v_ovr_factor := kut._mm_ovr_factor((c#>>'{trialist,ovr}')::int);
        v_form := kut._mm_form_roll(p_seed, 'form:t:' || v_user || ':' || v_slot);
        v_power := kut._mm_card_power(v_ovr_factor, v_form, (c#>>'{pick,neutralPpm}')::bigint, v_ppm,
          kut._mm_mul(v_handicap, (c#>>'{trialist,factorPpm}')::bigint));
        select * into v_lines from kut._mm_lines('all_rounder');
        v_entry_cards := v_entry_cards || jsonb_build_array(jsonb_build_object(
          'slot', v_slot, 'cardId', null, 'playerId', null, 'trialist', true,
          'ovr', (c#>>'{trialist,ovr}')::int, 'archetype', 'all_rounder', 'injured', false,
          'ovrFactorPpm', v_ovr_factor, 'formRollPpm', v_form, 'pickFactorPpm', (c#>>'{pick,neutralPpm}')::bigint,
          'fitnessPpm', v_ppm, 'handicapPpm', kut._mm_mul(v_handicap, (c#>>'{trialist,factorPpm}')::bigint),
          'powerPpm', v_power,
          'lines', jsonb_build_object('attPpm', v_lines.att_ppm, 'midPpm', v_lines.mid_ppm, 'defPpm', v_lines.def_ppm)));
      end if;
    end loop;

    -- shape.ts `chooseKeeper`: the strongest Goalkeeper, else the outfielder
    -- with the highest defence contribution; ties to the lower slot.
    v_keeper := -1; v_keeper_score := -1; v_keeperless := false;
    for v_slot in 0 .. v_size_cap - 1 loop
      v_card := v_entry_cards->v_slot;
      if v_card->>'archetype' = 'goalkeeper' and (v_card->>'powerPpm')::bigint > v_keeper_score then
        v_keeper := v_slot; v_keeper_score := (v_card->>'powerPpm')::bigint;
      end if;
    end loop;
    if v_keeper < 0 then
      v_keeperless := true;
      for v_slot in 0 .. v_size_cap - 1 loop
        v_card := v_entry_cards->v_slot;
        v_score := kut._mm_mul((v_card->>'powerPpm')::bigint, (v_card#>>'{lines,defPpm}')::bigint);
        if v_score > v_keeper_score then v_keeper := v_slot; v_keeper_score := v_score; end if;
      end loop;
    end if;

    -- shape.ts `squadBalance`: the weakest-line rule over the outfielders.
    v_balance := (kut._mm_balance(array(
      select card->>'archetype' from jsonb_array_elements(v_entry_cards) with ordinality as x(card, ord) order by ord),
      v_keeper)->>'balancePpm')::bigint;

    v_entries := v_entries || jsonb_build_array(jsonb_build_object(
      'userId', v_user, 'auto', v_auto, 'cards', v_entry_cards, 'keeperSlot', v_keeper, 'keeperless', v_keeperless,
      'balancePpm', v_balance));
    v_sides := v_sides || jsonb_build_object(v_user, jsonb_build_object(
      'cards', (select jsonb_agg(jsonb_build_object('archetype', card->'archetype', 'weekPowerPpm', card->'powerPpm',
        'lines', card->'lines') order by ord) from jsonb_array_elements(v_entry_cards) with ordinality as x(card, ord)),
      'keeperSlot', v_keeper, 'keeperless', v_keeperless, 'balancePpm', v_balance));
  end loop;

  -- bracket.ts `drawBracket`.
  select array_agg(e->>'userId' order by ord) into v_users
  from jsonb_array_elements(v_entries) with ordinality as x(e, ord);
  while v_size < v_count loop v_size := v_size * 2; v_rounds := v_rounds + 1; end loop;
  v_pairing_count := v_size / 2;
  v_bye_count := v_size - v_count;
  v_bye_pairings := (kut._mm_shuffle_order(p_seed, 'bracket:bye', v_pairing_count))[1 : v_bye_count];
  v_seat_order := kut._mm_shuffle_order(p_seed, 'bracket:seat', v_count);
  select array_agg(v_users[i + 1] order by ord) into v_seated from unnest(v_seat_order) with ordinality as x(i, ord);
  v_next := 1;
  for v_pairing in 0 .. v_pairing_count - 1 loop
    if v_pairing = any(coalesce(v_bye_pairings, '{}')) then
      v_first := v_first || v_seated[v_next]; v_second := v_second || null::text; v_next := v_next + 1;
    else
      v_first := v_first || v_seated[v_next]; v_second := v_second || v_seated[v_next + 1]; v_next := v_next + 2;
    end if;
  end loop;

  v_pays := kut._mm_round_payouts(v_rounds);
  for v_round in 1 .. v_rounds loop
    v_winners := '{}';
    for v_pairing in 0 .. cardinality(v_first) - 1 loop
      if v_second[v_pairing + 1] is null then
        v_byes := v_byes || jsonb_build_array(jsonb_build_object('pairing', v_pairing, 'userId', v_first[v_pairing + 1]));
        v_payouts := v_payouts || jsonb_build_array(jsonb_build_object(
          'userId', v_first[v_pairing + 1], 'round', v_round, 'amount', v_pays[v_round], 'bye', true));
        v_winners := v_winners || v_first[v_pairing + 1];
      else
        v_outcome := kut._mm_play_match(p_seed, 'm:' || v_round || ':' || v_pairing,
          v_sides->v_first[v_pairing + 1], v_sides->v_second[v_pairing + 1]);
        v_winner := case when (v_outcome->>'winnerSide')::int = 0 then v_first[v_pairing + 1] else v_second[v_pairing + 1] end;
        v_matches := v_matches || jsonb_build_array(jsonb_build_object(
          'round', v_round, 'pairing', v_pairing,
          'userIds', jsonb_build_array(v_first[v_pairing + 1], v_second[v_pairing + 1]), 'outcome', v_outcome));
        v_payouts := v_payouts || jsonb_build_array(jsonb_build_object(
          'userId', v_winner, 'round', v_round, 'amount', v_pays[v_round], 'bye', false));
        v_winners := v_winners || v_winner;
      end if;
    end loop;
    v_first := '{}'; v_second := '{}';
    for v_pairing in 0 .. cardinality(v_winners) / 2 - 1 loop
      v_first := v_first || v_winners[2 * v_pairing + 1];
      v_second := v_second || v_winners[2 * v_pairing + 2];
    end loop;
  end loop;

  return jsonb_build_object(
    'status', 'simulated', 'size', v_size, 'rounds', v_rounds, 'entries', v_entries,
    'pickShares', v_pick_shares, 'byes', v_byes, 'matches', v_matches, 'payouts', v_payouts,
    'championUserId', v_winners[1]);
end $$;

-- 6. The stored balance -------------------------------------------------------------
-- Null on every week locked before this push: those played without the rule.
alter table kut.midweek_entries
  add column balance_ppm integer check (balance_ppm between 1 and 1000000);

comment on column kut.midweek_entries.balance_ppm is
  'ADR-116: the weakest-line factor the squad played with (1000000 = no line short); null for weeks locked before ADR-116.';

-- 7. The lock step ------------------------------------------------------------------
-- As in 20261011000000_midweek_evening_timing.sql section 5, storing balance_ppm.
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

  insert into kut.midweek_entries (tournament_id, user_id, auto, keeper_slot, keeperless, balance_ppm)
  select p_tournament_id, (entry->>'userId')::uuid, (entry->>'auto')::boolean,
    (entry->>'keeperSlot')::smallint, (entry->>'keeperless')::boolean, (entry->>'balancePpm')::int
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

-- 8. The entries view: balance_ppm appended ----------------------------------------
-- As in 20261012000000_midweek_draw_from_lock.sql section 2, with balance_ppm
-- appended. It follows from the archetypes and the keeper, which show from the
-- lock, so it shows from the lock too.
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
  case when tournament.status = 'complete' and share.owners >= 3 then share.owners end as owners,
  entry.balance_ppm
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
  'ADR-091, ADR-095, ADR-105, ADR-116: every entered Midweek Madness card (engine slots 0-4) with its lock-time OVR, archetype, injury flag and factors, from the lock; form roll, pick factor and power only from round 1''s kick-off. Picks and owner counts only once complete; owners null below three. balance_ppm is the squad''s weakest-line factor, null before ADR-116. Gated on kut.is_active_member() (ADR-079).';

-- Every engine and internal function stays out of members' reach, the new one
-- included.
do $$ declare v_fn regprocedure; begin
  for v_fn in
    select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'kut' and p.proname like '\_mm\_%'
  loop
    execute format('revoke all on function %s from public, anon, authenticated', v_fn);
  end loop;
end $$;
