-- Midweek Madness, migration C: the engine, the lazy worker, the reveal
-- projections and the admin controls (BUILD_SPEC §44.3-§44.11, §44.14;
-- Part L #25; ADR-090, ADR-091, ADR-095).
--
-- The engine is authoritative here, in SQL, and is a line-for-line port of the
-- TypeScript twin in src/game/midweek/ (ADR-090). Both reproduce
-- tests/fixtures/midweek-golden.json: supabase/tests/database/
-- midweek_engine_parity.test.sql is generated from it by
-- `node scripts/midweek/golden.mjs`, and a unit test fails when it is stale.
-- A change to the engine changes both sides and regenerates both files.
--
--   1. kut._mm_*                  -- the engine: draws, factors, a match, a
--                                    whole tournament. Pure; internal only.
--   2. kut.midweek_entries / _entry_cards / _pick_shares / _matches /
--      _match_events / _jobs      -- the stored result and the worker log.
--   3. Part L #25 guards          -- a stored result is written once and
--                                    never changes; a tournament only moves
--                                    forward; squads are immutable after the
--                                    lock.
--   4. kut.run_midweek_due        -- the service-role worker: lock, complete,
--                                    open (§44.11).
--   5. kut.midweek_matches_public / _events_public / _entries_public /
--      _pick_shares_public / _admin_overview, and the champion appended to
--      kut.midweek_tournaments_public -- definer projections gated on
--                                    kut.is_active_member() and on time.
--   6. kut.admin_set_midweek_enabled / admin_void_midweek /
--      admin_midweek_rehearsal     -- the admin controls (§44.8).
--
-- Payment is not here: the worker's complete step publishes the seed and
-- marks the week complete, and the payout migration adds the coins to it
-- (Part L #26).
--
-- Tier: additive (docs/OPERATIONS.md). New tables, functions, views and
-- triggers; two nullable columns on kut.midweek_tournaments; the tournament
-- list view gains two columns at the end. The migration writes no row. The
-- worker it installs writes only when a tournament exists, and none can until
-- the switch, off on hosted, is turned on (§44.8); it moves no coin.
--
-- Rollback (the switch must be off and no tournament simulated):
--   drop function kut.admin_midweek_rehearsal(); drop function kut.admin_void_midweek(uuid, text);
--   drop function kut.admin_set_midweek_enabled(boolean);
--   drop view kut.midweek_admin_overview; drop view kut.midweek_pick_shares_public;
--   drop view kut.midweek_entries_public; drop view kut.midweek_events_public;
--   drop view kut.midweek_matches_public;
--   re-create kut.midweek_tournaments_public from 20261003000000_midweek_entry.sql
--     (drop it first: a view cannot lose columns);
--   drop function kut.run_midweek_due(integer);
--   drop trigger midweek_squads_guard on kut.midweek_squads;
--   drop trigger midweek_squad_cards_guard on kut.midweek_squad_cards;
--   drop trigger midweek_tournaments_guard on kut.midweek_tournaments;
--   drop table kut.midweek_jobs, kut.midweek_match_events, kut.midweek_matches,
--     kut.midweek_pick_shares, kut.midweek_entry_cards, kut.midweek_entries;
--   alter table kut.midweek_tournaments drop column voided_by, drop column voided_at;
--   then every remaining kut._mm_* function.

-- 1. Engine ------------------------------------------------------------------
-- A line-for-line port of src/game/midweek/*. Every value is a bigint in parts
-- per million and every division is of non-negative integers, so bigint `/`
-- (which truncates) is the TypeScript `idiv` (which floors). The parity test
-- generated from tests/fixtures/midweek-golden.json pins the two together.
-- Engine indexes are 0-based (slots, sides, pairings), as in TypeScript.

-- The tunables, verbatim from MIDWEEK in src/game/midweek/config.ts. The
-- parity test compares this object with the fixture's, key for key.
create function kut._mm_config()
returns jsonb language sql immutable parallel safe set search_path = kut, pg_catalog as $$
  select '{"squadSize":5,"minEntrants":4,"championTotal":250,"ownerCountMin":3,"schedule":{"lockDayOffset":2,"lockHourLocal":20,"revealIntervalMinutes":30},"ovr":{"min":30,"max":83,"factorMaxPpm":1100000},"form":{"minPpm":800000,"modePpm":1000000,"maxPpm":1250000,"dice":2},"pick":{"points":[[0,1250000],[400000,1000000],[1000000,875000]],"smoothingPicks":1,"smoothingOwners":3,"neutralPpm":1000000},"dayRollSpreadPpm":120000,"injuredFitnessPpm":950000,"autoFactorPpm":575000,"trialist":{"ovr":30,"factorPpm":825000},"shape":{"scalePpm":500000,"minMultPpm":100000},"keeperlessFactorPpm":450000,"keeperCreatorWeightPpm":150000,"keeperShooterWeightPpm":5000,"match":{"intendedGoalsPerMatch":2.5,"chanceSlots":14,"chanceRatePpm":686000,"midfieldContrast":1,"goalBasePpm":300000,"finishingContrast":1,"goalMinPpm":20000,"goalMaxPpm":850000,"minutes":90,"missWeights":{"save":45,"block":25,"woodwork":8,"wide":22}},"penalties":{"kicks":5,"basePpm":750000,"contrast":1,"minPpm":400000,"maxPpm":950000,"maxSuddenDeathRounds":20,"missWeights":{"save":60,"woodwork":15,"wide":25}},"winChanceContrast":3,"chanceTypes":{"solo":["breakaway","wing_run","long_shot","curler","scramble","free_kick"],"base":{"breakaway":3,"wing_run":3,"chase":2,"volley":2,"first_time":4,"overhead":0,"through_ball":4,"free_kick":2,"curler":3,"header":3,"scramble":4,"long_shot":3,"long_throw":0,"cutback":5,"one_two":4},"creatorBonus":{"all_rounder":{},"speedster":{"wing_run":5,"cutback":3},"finisher":{"one_two":2},"playmaker":{"through_ball":6,"free_kick":3,"one_two":3},"defender":{"header":2,"scramble":2},"tank":{"header":2,"scramble":2},"goalkeeper":{"long_throw":8,"breakaway":3}},"shooterBonus":{"all_rounder":{},"speedster":{"breakaway":6,"chase":6,"wing_run":2},"finisher":{"volley":5,"first_time":6,"overhead":1},"playmaker":{"curler":5,"free_kick":4},"defender":{"header":6,"scramble":4,"long_shot":3},"tank":{"header":6,"scramble":4,"long_shot":4},"goalkeeper":{"long_shot":2}},"difficultyPpm":{"breakaway":1200000,"wing_run":850000,"chase":1000000,"volley":800000,"first_time":1000000,"overhead":400000,"through_ball":1100000,"free_kick":550000,"curler":700000,"header":900000,"scramble":1150000,"long_shot":450000,"long_throw":900000,"cutback":1250000,"one_two":1100000}}}'::jsonb
$$;

-- CHANCE_TYPES in its declared order, which the weighted chance-type draw
-- walks. jsonb does not keep key order, so the order lives here.
create function kut._mm_chance_types()
returns text[] language sql immutable parallel safe set search_path = kut, pg_catalog as $$
  select array['breakaway','wing_run','chase','volley','first_time','overhead','through_ball',
    'free_kick','curler','header','scramble','long_shot','long_throw','cutback','one_two']
$$;

-- rng.ts: sha256(seed || tag), the first 6 bytes as an integer in [0, 2^48).
create function kut._mm_draw(p_seed bytea, p_tag text)
returns bigint language sql immutable strict parallel safe set search_path = kut, pg_catalog as $$
  select ('x' || encode(substring(sha256(p_seed || convert_to(p_tag, 'UTF8')) from 1 for 6), 'hex'))::bit(48)::bigint
$$;

-- rng.ts `uniform`: the draw modulo n.
create function kut._mm_uniform(p_seed bytea, p_tag text, p_n bigint)
returns bigint language plpgsql immutable parallel safe set search_path = kut, pg_catalog as $$
begin
  if p_n is null or p_n < 1 or p_n > 4294967296 then
    raise exception 'Midweek uniform range out of bounds: %', p_n using errcode = '22003';
  end if;
  return kut._mm_draw(p_seed, p_tag) % p_n;
end $$;

-- rng.ts `pickWeighted`: the 0-based index the draw lands on, walking the
-- cumulative weights in array order.
create function kut._mm_pick_weighted(p_seed bytea, p_tag text, p_weights bigint[])
returns integer language plpgsql immutable parallel safe set search_path = kut, pg_catalog as $$
declare v_total bigint := 0; v_target bigint; v_i integer;
begin
  for v_i in 1 .. coalesce(cardinality(p_weights), 0) loop
    v_total := v_total + p_weights[v_i];
  end loop;
  if v_total <= 0 then raise exception 'Midweek weighted choice with no weight' using errcode = '22003'; end if;
  v_target := kut._mm_uniform(p_seed, p_tag, v_total);
  for v_i in 1 .. cardinality(p_weights) loop
    if v_target < p_weights[v_i] then return v_i - 1; end if;
    v_target := v_target - p_weights[v_i];
  end loop;
  raise exception 'unreachable';
end $$;

-- rng.ts `shuffle` applied to [0, n): Fisher-Yates from the back, one tagged
-- draw per position. Shuffling any n items is items[result[i]].
create function kut._mm_shuffle_order(p_seed bytea, p_tag text, p_n integer)
returns integer[] language plpgsql immutable parallel safe set search_path = kut, pg_catalog as $$
declare v_result integer[]; v_i integer; v_swap integer; v_tmp integer;
begin
  select coalesce(array_agg(i order by i), '{}') into v_result from generate_series(0, p_n - 1) i;
  for v_i in reverse p_n - 1 .. 1 loop
    v_swap := kut._mm_uniform(p_seed, p_tag || ':' || v_i, v_i + 1);
    v_tmp := v_result[v_i + 1];
    v_result[v_i + 1] := v_result[v_swap + 1];
    v_result[v_swap + 1] := v_tmp;
  end loop;
  return v_result;
end $$;

-- fixed.ts `mulPpm`: a × b in ppm, floored.
create function kut._mm_mul(p_a bigint, p_b bigint)
returns bigint language sql immutable strict parallel safe set search_path = kut, pg_catalog as $$
  select p_a * p_b / 1000000
$$;

-- fixed.ts `powerSharePpm`: a^k / (a^k + b^k) in ppm. Both values are divided
-- by the same power of ten until the larger power is at most 9e9; the test is
-- made in numeric so it cannot overflow, the powers themselves in bigint.
create function kut._mm_power_share(p_a bigint, p_b bigint, p_k integer)
returns bigint language plpgsql immutable parallel safe set search_path = kut, pg_catalog as $$
declare v_divisor bigint := 1; v_big numeric; v_x bigint; v_y bigint; v_i integer;
begin
  if p_a < 0 or p_b < 0 then raise exception 'Midweek power share of a negative value' using errcode = '22003'; end if;
  loop
    v_big := 1;
    for v_i in 1 .. p_k loop v_big := v_big * greatest(p_a / v_divisor, p_b / v_divisor); end loop;
    exit when v_big <= 9000000000;
    v_divisor := v_divisor * 10;
  end loop;
  v_x := 1; v_y := 1;
  for v_i in 1 .. p_k loop
    v_x := v_x * (p_a / v_divisor);
    v_y := v_y * (p_b / v_divisor);
  end loop;
  if v_x + v_y = 0 then return 500000; end if;
  return v_x * 1000000 / (v_x + v_y);
end $$;

-- power.ts `ovrFactorPpm`: 1.00 at OVR 30, the maximum at 83, linear and clamped.
create function kut._mm_ovr_factor(p_ovr integer)
returns bigint language sql immutable strict parallel safe set search_path = kut, pg_catalog as $$
  select 1000000 + ((c->>'factorMaxPpm')::bigint - 1000000)
    * (least(greatest(p_ovr, (c->>'min')::int), (c->>'max')::int) - (c->>'min')::int)
    / ((c->>'max')::int - (c->>'min')::int)
  from (select kut._mm_config()->'ovr' as c) config
$$;

-- power.ts `formRollPpm`: the mean of the dice, its lower half mapped onto
-- [min, mode) and its upper half onto [mode, max).
create function kut._mm_form_roll(p_seed bytea, p_tag text)
returns bigint language plpgsql immutable parallel safe set search_path = kut, pg_catalog as $$
declare
  c jsonb := kut._mm_config()->'form';
  v_min bigint := (c->>'minPpm')::bigint; v_mode bigint := (c->>'modePpm')::bigint;
  v_max bigint := (c->>'maxPpm')::bigint; v_dice integer := (c->>'dice')::int;
  v_sum bigint := 0; v_u bigint; v_die integer;
begin
  for v_die in 0 .. v_dice - 1 loop
    v_sum := v_sum + kut._mm_uniform(p_seed, p_tag || ':' || v_die, 1000000);
  end loop;
  v_u := v_sum / v_dice;
  if v_u < 500000 then return v_min + (v_mode - v_min) * v_u / 500000; end if;
  return v_mode + (v_max - v_mode) * (v_u - 500000) / 500000;
end $$;

-- power.ts `dayRollPpm`: uniform in [PPM − spread, PPM + spread].
create function kut._mm_day_roll(p_seed bytea, p_tag text)
returns bigint language sql immutable strict parallel safe set search_path = kut, pg_catalog as $$
  select 1000000 - spread + kut._mm_uniform(p_seed, p_tag, 2 * spread + 1)
  from (select (kut._mm_config()->>'dayRollSpreadPpm')::bigint as spread) config
$$;

-- power.ts `pickSharePpm`: (picks + 1) / (owners + 3), in ppm.
create function kut._mm_pick_share(p_picks integer, p_owners integer)
returns bigint language plpgsql immutable parallel safe set search_path = kut, pg_catalog as $$
declare c jsonb := kut._mm_config()->'pick';
begin
  if p_picks > p_owners then
    raise exception 'A Player cannot be picked by more entrants than own it' using errcode = '22023';
  end if;
  return (p_picks + (c->>'smoothingPicks')::int)::bigint * 1000000 / (p_owners + (c->>'smoothingOwners')::int);
end $$;

-- power.ts `pickFactorPpm`: piecewise linear over the configured points.
create function kut._mm_pick_factor(p_share bigint)
returns bigint language plpgsql immutable parallel safe set search_path = kut, pg_catalog as $$
declare
  v_points jsonb := kut._mm_config()#>'{pick,points}';
  v_n integer := jsonb_array_length(v_points);
  v_share bigint; v_i integer; v_x0 bigint; v_y0 bigint; v_x1 bigint; v_y1 bigint;
begin
  v_share := least(greatest(p_share, (v_points->0->>0)::bigint), (v_points->(v_n - 1)->>0)::bigint);
  for v_i in 1 .. v_n - 1 loop
    v_x0 := (v_points->(v_i - 1)->>0)::bigint; v_y0 := (v_points->(v_i - 1)->>1)::bigint;
    v_x1 := (v_points->v_i->>0)::bigint; v_y1 := (v_points->v_i->>1)::bigint;
    continue when v_share > v_x1;
    if v_y1 <= v_y0 then return v_y0 - (v_y0 - v_y1) * (v_share - v_x0) / (v_x1 - v_x0); end if;
    return v_y0 + (v_y1 - v_y0) * (v_share - v_x0) / (v_x1 - v_x0);
  end loop;
  return (v_points->(v_n - 1)->>1)::bigint;
end $$;

-- power.ts `cardPowerPpm`: the factors multiplied left to right, floored after each.
create function kut._mm_card_power(p_ovr_factor bigint, p_form bigint, p_pick bigint, p_fitness bigint, p_handicap bigint)
returns bigint language sql immutable strict parallel safe set search_path = kut, pg_catalog as $$
  select kut._mm_mul(kut._mm_mul(kut._mm_mul(kut._mm_mul(p_ovr_factor, p_form), p_pick), p_fitness), p_handicap)
$$;

-- shape.ts `lineMultsPpm`: each line's mean archetype offset (§15.1, the
-- ARCHETYPE_OFFSETS of src/game/rating-engine.ts), scaled and floored.
create function kut._mm_lines(p_archetype text, out att_ppm bigint, out mid_ppm bigint, out def_ppm bigint)
language plpgsql immutable parallel safe set search_path = kut, pg_catalog as $$
declare
  c jsonb := kut._mm_config()->'shape';
  v_scale bigint := (c->>'scalePpm')::bigint; v_min bigint := (c->>'minMultPpm')::bigint;
  o record;
begin
  select * into o from (values
    ('all_rounder', 0, 0, 0, 0, 0, 0),
    ('speedster', 10, -1, -2, 4, -6, -5),
    ('finisher', 2, 10, -3, 3, -8, -4),
    ('playmaker', -2, -2, 10, 5, -6, -5),
    ('defender', -2, -7, -1, -4, 10, 4),
    ('tank', -8, -2, -2, -4, 4, 12),
    ('goalkeeper', -6, -12, 0, -8, 14, 12)
  ) offsets(archetype, pac, sho, pas, dri, def, phy)
  where offsets.archetype = p_archetype;
  if not found then raise exception 'unknown archetype %', p_archetype using errcode = '22023'; end if;
  att_ppm := greatest(30 * 1000000 + v_scale * (o.sho + o.pac + o.dri), 30 * v_min) / 30;
  mid_ppm := greatest(20 * 1000000 + v_scale * (o.pas + o.dri), 20 * v_min) / 20;
  def_ppm := greatest(20 * 1000000 + v_scale * (o.def + o.phy), 20 * v_min) / 20;
end $$;

-- match.ts `chanceTypeWeights`, in _mm_chance_types() order.
create function kut._mm_chance_type_weights(p_creator text, p_shooter text, p_solo boolean)
returns bigint[] language sql immutable parallel safe set search_path = kut, pg_catalog as $$
  select array_agg(
    case when p_solo and not ((t->'solo') ? chance_type) then 0
    else (t->'base'->>chance_type)::bigint
      + coalesce((t->'creatorBonus'->p_creator->>chance_type)::bigint, 0)
      + coalesce((t->'shooterBonus'->p_shooter->>chance_type)::bigint, 0)
    end order by ord)
  from unnest(kut._mm_chance_types()) with ordinality as types(chance_type, ord),
    (select kut._mm_config()->'chanceTypes' as t) config
$$;

-- rewards.ts `roundPayouts`: round r of R pays round_half_up(total × r / T),
-- T = R(R+1)/2, and the final absorbs the rounding.
create function kut._mm_round_payouts(p_rounds integer)
returns integer[] language plpgsql immutable parallel safe set search_path = kut, pg_catalog as $$
declare
  v_total integer := (kut._mm_config()->>'championTotal')::int;
  v_triangle integer; v_pays integer[] := '{}'; v_sum integer := 0; v_pay integer; v_round integer;
begin
  if p_rounds is null or p_rounds < 1 then
    raise exception 'A tournament has at least one round' using errcode = '22023';
  end if;
  v_triangle := p_rounds * (p_rounds + 1) / 2;
  for v_round in 1 .. p_rounds - 1 loop
    v_pay := (2 * v_total * v_round + v_triangle) / (2 * v_triangle);
    v_pays := v_pays || v_pay;
    v_sum := v_sum + v_pay;
  end loop;
  return v_pays || (v_total - v_sum);
end $$;

-- schedule.ts `lockAt`: Wednesday 20:00 Europe/Amsterdam of the football week
-- starting on this ISO Monday.
create function kut._mm_lock_at(p_week_start date)
returns timestamptz language plpgsql stable parallel safe set search_path = kut, pg_catalog as $$
declare c jsonb := kut._mm_config()->'schedule';
begin
  if p_week_start is null or extract(isodow from p_week_start) <> 1 then
    raise exception 'Expected an ISO Monday, received %', p_week_start using errcode = '22023';
  end if;
  return ((p_week_start + (c->>'lockDayOffset')::int) + make_time((c->>'lockHourLocal')::int, 0, 0))
    at time zone 'Europe/Amsterdam';
end $$;

-- schedule.ts `revealAt`: round r appears 30 elapsed minutes × r after the lock.
create function kut._mm_reveal_at(p_lock_at timestamptz, p_round integer)
returns timestamptz language sql immutable strict parallel safe set search_path = kut, pg_catalog as $$
  select p_lock_at + make_interval(mins => (kut._mm_config()#>>'{schedule,revealIntervalMinutes}')::int * p_round)
$$;

-- match.ts `playMatch`: one match as chances, then penalties on a draw. Sides
-- are the engine's MatchSide objects and the result its MatchOutcome, so the
-- parity test compares them whole. Both sides' cards sit in flat arrays: side
-- s, slot i is element v_base[s + 1] + i + 1.
create function kut._mm_play_match(p_seed bytea, p_prefix text, p_a jsonb, p_b jsonb)
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

      -- sideRatingPpm, from the week-long power.
      if v_i = v_keeper[v_s + 1] then
        v_rating[v_s + 1] := v_rating[v_s + 1] + case when v_keeperless[v_s + 1]
          then kut._mm_mul(kut._mm_mul(v_week, v_defm), v_keeperless_factor) else kut._mm_mul(v_week, v_defm) end;
      else
        v_rating[v_s + 1] := v_rating[v_s + 1] + kut._mm_mul(v_week, v_attm) + kut._mm_mul(v_week, v_midm)
          + kut._mm_mul(v_week, v_defm);
      end if;

      v_day := v_day || kut._mm_day_roll(p_seed, p_prefix || ':day:' || v_s || ':' || v_i);
      v_power := kut._mm_mul(v_week, v_day[v_base[v_s + 1] + v_i + 1]);
      v_att := v_att || kut._mm_mul(v_power, v_attm);
      v_mid := v_mid || kut._mm_mul(v_power, v_midm);
      v_def := v_def || kut._mm_mul(v_power, v_defm);
      if v_i = v_keeper[v_s + 1] then
        v_keeper_strength[v_s + 1] := case when v_keeperless[v_s + 1]
          then kut._mm_mul(kut._mm_mul(v_power, v_defm), v_keeperless_factor) else kut._mm_mul(v_power, v_defm) end;
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

    v_resistance := (v_def_total[v_opp + 1] / (v_n[v_opp + 1] - 1) + v_keeper_strength[v_opp + 1]) / 2;
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

-- tournament.ts `autoSquad`: up to five random distinct Players from the
-- collection, one copy each, both chosen by tagged draws (ties by id).
create function kut._mm_auto_squad(p_seed bytea, p_entrant jsonb)
returns jsonb language sql immutable parallel safe set search_path = kut, pg_catalog as $$
  with owned as (
    select card, card->>'playerId' as player_id, card->>'cardId' as card_id, ord
    from jsonb_array_elements(p_entrant->'owned') with ordinality as o(card, ord)
  ),
  players as (
    select player_id, kut._mm_draw(p_seed, 'auto:p:' || (p_entrant->>'userId') || ':' || player_id) as draw
    from (select distinct player_id from owned) distinct_players
    order by draw, player_id collate "C"
    limit (kut._mm_config()->>'squadSize')::int
  )
  select coalesce(jsonb_agg(chosen.card order by players.draw, players.player_id collate "C"), '[]'::jsonb)
  from players
  cross join lateral (
    select owned.card from owned
    where owned.player_id = players.player_id
    order by kut._mm_draw(p_seed, 'auto:c:' || (p_entrant->>'userId') || ':' || owned.card_id), owned.card_id collate "C", owned.ord
    limit 1
  ) chosen
$$;

-- tournament.ts `simulateTournament` (with `buildField`, `drawBracket` and
-- `toMatchSide`): the whole tournament as one pure function of the seed and
-- the field. Entrants and the result are the engine's EntrantInput[] and
-- TournamentResult. The worker stores the result; the rehearsal only reads it.
create function kut._mm_simulate(p_seed bytea, p_entrants jsonb)
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
  v_keeper integer; v_keeper_score bigint; v_keeperless boolean; v_score bigint;
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

    v_entries := v_entries || jsonb_build_array(jsonb_build_object(
      'userId', v_user, 'auto', v_auto, 'cards', v_entry_cards, 'keeperSlot', v_keeper, 'keeperless', v_keeperless));
    v_sides := v_sides || jsonb_build_object(v_user, jsonb_build_object(
      'cards', (select jsonb_agg(jsonb_build_object('archetype', card->'archetype', 'weekPowerPpm', card->'powerPpm',
        'lines', card->'lines') order by ord) from jsonb_array_elements(v_entry_cards) with ordinality as x(card, ord)),
      'keeperSlot', v_keeper, 'keeperless', v_keeperless));
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

-- 2. Stored results -------------------------------------------------------------
-- Written once by the lock step, in the engine's 0-based indexes (slot 0-4,
-- side 0-1, pairing from 0), so a page hands them to the renderer unchanged.
-- Squad slots in kut.midweek_squad_cards stay 1-5: they are the member's picks
-- in order, and the lock compacts the surviving picks into engine slots.

alter table kut.midweek_tournaments
  add column voided_at timestamptz,
  add column voided_by uuid references kut.profiles(id) on delete set null;

create table kut.midweek_entries (
  tournament_id uuid not null references kut.midweek_tournaments(id) on delete cascade,
  user_id uuid not null references kut.profiles(id) on delete cascade,
  -- No saved card survived the lock, so the engine drew the squad (§44.2).
  auto boolean not null,
  keeper_slot smallint not null check (keeper_slot between 0 and 4),
  keeperless boolean not null,
  primary key (tournament_id, user_id)
);

create table kut.midweek_entry_cards (
  tournament_id uuid not null,
  user_id uuid not null,
  slot smallint not null check (slot between 0 and 4),
  trialist boolean not null,
  -- The Card Copy as it was at the lock. No foreign key: the snapshot outlives
  -- a later trade or burn of the copy.
  card_id uuid,
  player_id uuid references kut.players(id) on delete restrict,
  ovr smallint not null check (ovr between 1 and 99),
  archetype text not null,
  injured boolean not null,
  ovr_factor_ppm integer not null check (ovr_factor_ppm > 0),
  form_roll_ppm integer not null check (form_roll_ppm > 0),
  pick_factor_ppm integer not null check (pick_factor_ppm > 0),
  fitness_ppm integer not null check (fitness_ppm > 0),
  handicap_ppm integer not null check (handicap_ppm > 0),
  power_ppm integer not null check (power_ppm > 0),
  att_ppm integer not null check (att_ppm > 0),
  mid_ppm integer not null check (mid_ppm > 0),
  def_ppm integer not null check (def_ppm > 0),
  primary key (tournament_id, user_id, slot),
  foreign key (tournament_id, user_id) references kut.midweek_entries(tournament_id, user_id) on delete cascade,
  check (trialist = (card_id is null) and trialist = (player_id is null))
);

-- Owners count every entrant owning the Player at the lock; picks count only
-- squads the members chose (§44.3). Published once the week is complete.
create table kut.midweek_pick_shares (
  tournament_id uuid not null references kut.midweek_tournaments(id) on delete cascade,
  player_id uuid not null references kut.players(id) on delete restrict,
  owners smallint not null check (owners >= 1),
  picks smallint not null check (picks between 0 and owners),
  share_ppm integer not null check (share_ppm between 0 and 1000000),
  pick_factor_ppm integer not null check (pick_factor_ppm > 0),
  primary key (tournament_id, player_id)
);

-- Every round-1 pairing, including a bye (a single entrant who goes through),
-- and every later match, each with the moment it is revealed.
create table kut.midweek_matches (
  id uuid primary key default gen_random_uuid(),
  tournament_id uuid not null references kut.midweek_tournaments(id) on delete cascade,
  round smallint not null check (round between 1 and 10),
  pairing smallint not null check (pairing >= 0),
  bye boolean not null,
  side_0_user_id uuid not null,
  side_1_user_id uuid,
  side_0_goals smallint check (side_0_goals >= 0),
  side_1_goals smallint check (side_1_goals >= 0),
  -- Set only when a draw went to penalties.
  side_0_penalties smallint check (side_0_penalties >= 0),
  side_1_penalties smallint check (side_1_penalties >= 0),
  winner_side smallint not null check (winner_side in (0, 1)),
  winner_user_id uuid not null,
  -- Side 0's pre-match win chance, from the week-long factors (§44.5).
  win_chance_ppm integer check (win_chance_ppm between 0 and 1000000),
  -- Each card's day roll in this match, by engine slot (HANDOFF open question 4).
  side_0_day_rolls_ppm integer[],
  side_1_day_rolls_ppm integer[],
  reveal_at timestamptz not null,
  unique (tournament_id, round, pairing),
  foreign key (tournament_id, side_0_user_id) references kut.midweek_entries(tournament_id, user_id) on delete cascade,
  foreign key (tournament_id, side_1_user_id) references kut.midweek_entries(tournament_id, user_id) on delete cascade,
  check (bye = (side_1_user_id is null)),
  check (not bye or (round = 1 and winner_side = 0)),
  check (bye = (side_0_goals is null) and bye = (side_1_goals is null) and bye = (win_chance_ppm is null)
    and bye = (side_0_day_rolls_ppm is null) and bye = (side_1_day_rolls_ppm is null)),
  check ((side_0_penalties is null) = (side_1_penalties is null)),
  check (side_0_penalties is null or side_0_goals = side_1_goals),
  check (winner_user_id = case winner_side when 0 then side_0_user_id else side_1_user_id end)
);
create index midweek_matches_side_0_idx on kut.midweek_matches (tournament_id, side_0_user_id);
create index midweek_matches_side_1_idx on kut.midweek_matches (tournament_id, side_1_user_id);

-- A match's events in the engine's order: chances, penalty kicks, and the
-- draw that settles a shoot-out still level after sudden death.
create table kut.midweek_match_events (
  match_id uuid not null references kut.midweek_matches(id) on delete cascade,
  seq smallint not null check (seq >= 0),
  kind text not null check (kind in ('chance', 'penalty', 'toss')),
  side smallint not null check (side in (0, 1)),
  minute smallint check (minute between 1 and 90),
  penalty_round smallint check (penalty_round >= 1),
  creator_slot smallint check (creator_slot between 0 and 4),
  shooter_slot smallint check (shooter_slot between 0 and 4),
  -- The keeper for a save, the defender for a block or a shot forced wide.
  defender_slot smallint check (defender_slot between 0 and 4),
  kicker_slot smallint check (kicker_slot between 0 and 4),
  keeper_slot smallint check (keeper_slot between 0 and 4),
  chance_type text check (chance_type in ('breakaway', 'wing_run', 'chase', 'volley', 'first_time', 'overhead',
    'through_ball', 'free_kick', 'curler', 'header', 'scramble', 'long_shot', 'long_throw', 'cutback', 'one_two')),
  outcome text check (outcome in ('goal', 'save', 'block', 'woodwork', 'wide')),
  p_goal_ppm integer check (p_goal_ppm between 0 and 1000000),
  primary key (match_id, seq),
  check (case kind
    when 'chance' then minute is not null and creator_slot is not null and shooter_slot is not null
      and chance_type is not null and outcome is not null and p_goal_ppm is not null
      and penalty_round is null and kicker_slot is null and keeper_slot is null
      and (defender_slot is null) = (outcome in ('goal', 'woodwork'))
    when 'penalty' then penalty_round is not null and kicker_slot is not null and keeper_slot is not null
      and outcome in ('goal', 'save', 'woodwork', 'wide') and p_goal_ppm is not null
      and minute is null and creator_slot is null and shooter_slot is null and defender_slot is null
      and chance_type is null
    else minute is null and penalty_round is null and creator_slot is null and shooter_slot is null
      and defender_slot is null and kicker_slot is null and keeper_slot is null and chance_type is null
      and outcome is null and p_goal_ppm is null
  end)
);

-- One row per worker call, as kut.session_survey_jobs.
create table kut.midweek_jobs (
  id bigint generated always as identity primary key,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  locked_count integer not null default 0,
  completed_count integer not null default 0,
  opened_count integer not null default 0,
  error_text text
);

alter table kut.midweek_entries enable row level security;
alter table kut.midweek_entry_cards enable row level security;
alter table kut.midweek_pick_shares enable row level security;
alter table kut.midweek_matches enable row level security;
alter table kut.midweek_match_events enable row level security;
alter table kut.midweek_jobs enable row level security;
revoke all on kut.midweek_entries, kut.midweek_entry_cards, kut.midweek_pick_shares, kut.midweek_matches,
  kut.midweek_match_events, kut.midweek_jobs
  from public, anon, authenticated;
grant select on kut.midweek_entries, kut.midweek_entry_cards, kut.midweek_pick_shares, kut.midweek_matches,
  kut.midweek_match_events, kut.midweek_jobs
  to service_role;

-- 3. Part L #25: simulated once, a stored result never changes, squads are
-- immutable after the lock --------------------------------------------------------
-- Each guard lets a cascading delete through (a deleted tournament or account
-- takes its rows with it): a delete issued by a foreign key's cascade runs one
-- trigger level down, so pg_trigger_depth() is above 1.

-- Result rows are written only while the lock step holds an open tournament,
-- and never updated or deleted directly afterwards.
create function kut._mm_guard_result()
returns trigger language plpgsql set search_path = kut, pg_catalog as $$
declare v_tournament uuid; v_status text;
begin
  if tg_op = 'UPDATE' then
    raise exception 'a stored Midweek result is final (%)', tg_table_name using errcode = '55000';
  end if;
  if tg_op = 'DELETE' then
    if pg_trigger_depth() > 1 then return old; end if;
    raise exception 'a stored Midweek result is final (%)', tg_table_name using errcode = '55000';
  end if;
  if tg_table_name = 'midweek_match_events' then
    select tournament_id into v_tournament from kut.midweek_matches where id = new.match_id;
  else
    v_tournament := new.tournament_id;
  end if;
  select status into v_status from kut.midweek_tournaments where id = v_tournament;
  if v_status is distinct from 'open' then
    raise exception 'Midweek results are written once, when the tournament locks' using errcode = '55000';
  end if;
  return new;
end $$;

create trigger midweek_entries_guard before insert or update or delete on kut.midweek_entries
  for each row execute function kut._mm_guard_result();
create trigger midweek_entry_cards_guard before insert or update or delete on kut.midweek_entry_cards
  for each row execute function kut._mm_guard_result();
create trigger midweek_pick_shares_guard before insert or update or delete on kut.midweek_pick_shares
  for each row execute function kut._mm_guard_result();
create trigger midweek_matches_guard before insert or update or delete on kut.midweek_matches
  for each row execute function kut._mm_guard_result();
create trigger midweek_match_events_guard before insert or update or delete on kut.midweek_match_events
  for each row execute function kut._mm_guard_result();

-- A tournament moves only forward (§44.8): open -> skipped, simulated or void;
-- simulated -> complete or void. Its week and commitment never change, its
-- lock only while open, its bracket size once drawn, and the seed published at
-- completion must be the one committed to.
create function kut._mm_guard_tournament()
returns trigger language plpgsql set search_path = kut, pg_catalog as $$
begin
  if new.week_start is distinct from old.week_start or new.seed_hash is distinct from old.seed_hash then
    raise exception 'a Midweek tournament''s week and seed hash never change' using errcode = '55000';
  end if;
  if old.status <> 'open' and new.lock_at is distinct from old.lock_at then
    raise exception 'a Midweek tournament''s lock is fixed once it has locked' using errcode = '55000';
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

create trigger midweek_tournaments_guard before update on kut.midweek_tournaments
  for each row execute function kut._mm_guard_tournament();

-- Squads are immutable once the lock has passed. An AFTER trigger, so a row
-- that breaks a constraint still fails with that constraint's error.
create function kut._mm_guard_squad()
returns trigger language plpgsql set search_path = kut, pg_catalog as $$
declare v_squad uuid; v_tournament uuid; v_locked boolean;
begin
  if tg_op = 'DELETE' and pg_trigger_depth() > 1 then return null; end if;
  if tg_table_name = 'midweek_squad_cards' then
    v_squad := case when tg_op = 'DELETE' then old.squad_id else new.squad_id end;
    select tournament_id into v_tournament from kut.midweek_squads where id = v_squad;
  else
    v_tournament := case when tg_op = 'DELETE' then old.tournament_id else new.tournament_id end;
  end if;
  select status <> 'open' or now() >= lock_at into v_locked from kut.midweek_tournaments where id = v_tournament;
  if v_locked then
    raise exception 'squads are locked' using errcode = 'P0001';
  end if;
  return null;
end $$;

create trigger midweek_squads_guard after insert or update or delete on kut.midweek_squads
  for each row execute function kut._mm_guard_squad();
create trigger midweek_squad_cards_guard after insert or update or delete on kut.midweek_squad_cards
  for each row execute function kut._mm_guard_squad();

revoke all on function kut._mm_guard_result(), kut._mm_guard_tournament(), kut._mm_guard_squad()
  from public, anon, authenticated;

-- 4. The worker --------------------------------------------------------------------

-- The field as of p_as_of (§44.1-§44.3): every active member who owns an
-- active card and had not opted out by then, with every card they own and
-- whatever of their saved squad for p_tournament_id is still theirs, as the
-- engine's EntrantInput[] (null p_tournament_id: nobody has picked). OVR is
-- read as my_collection_cards reads it, the archetype from the Player as every
-- card screen shows it, and the injury flag by the ADR-085 cast rule: a Live
-- copy of a Player in injury mode. Warnings name each saved card that was lost.
create function kut._mm_field(p_tournament_id uuid, p_as_of timestamptz)
returns jsonb language plpgsql stable security definer set search_path = kut, pg_catalog as $$
declare v_entrants jsonb; v_warnings jsonb;
begin
  with members as (
    select profile.id as user_id, profile.display_name
    from kut.profiles profile
    where not profile.is_disabled
      and not exists (
        select 1 from kut.midweek_opt_outs opt_out
        where opt_out.user_id = profile.id and opt_out.opted_out_at <= p_as_of)
  ),
  cards as (
    select card.owner_id as user_id, card.id as card_id, edition.player_id,
      coalesce(edition.snapshot_ovr, state.live_ovr, 30) as ovr,
      player.archetype,
      edition.is_live and kut._active_injury_period(player.id) is not null as injured
    from kut.user_cards card
    join members on members.user_id = card.owner_id
    join kut.card_editions edition on edition.id = card.edition_id
    join kut.players player on player.id = edition.player_id
    left join kut.seasons active_season on active_season.is_active
    left join kut.player_season_state state on state.player_id = player.id and state.season_id = active_season.id
    where card.burned_at is null
  ),
  saved as (
    select squad.user_id, squad_card.slot, squad_card.card_id,
      exists (select 1 from cards where cards.card_id = squad_card.card_id and cards.user_id = squad.user_id) as kept
    from kut.midweek_squads squad
    join kut.midweek_squad_cards squad_card on squad_card.squad_id = squad.id
    where squad.tournament_id = p_tournament_id
  )
  select
    coalesce(jsonb_agg(jsonb_build_object(
      'userId', members.user_id,
      'saved', coalesce((
        select jsonb_agg(jsonb_build_object('cardId', cards.card_id, 'playerId', cards.player_id, 'ovr', cards.ovr,
          'archetype', cards.archetype, 'injured', cards.injured) order by saved.slot)
        from saved join cards on cards.card_id = saved.card_id
        where saved.user_id = members.user_id and saved.kept), '[]'::jsonb),
      'owned', (
        select jsonb_agg(jsonb_build_object('cardId', cards.card_id, 'playerId', cards.player_id, 'ovr', cards.ovr,
          'archetype', cards.archetype, 'injured', cards.injured) order by cards.card_id)
        from cards where cards.user_id = members.user_id)
    ) order by members.user_id), '[]'::jsonb),
    (select coalesce(jsonb_agg(jsonb_build_object('level', 'warning', 'message', format(
        case when exists (select 1 from saved kept where kept.user_id = lost.user_id and kept.kept)
          then '%s: the card saved in slot %s is no longer theirs, so a trialist plays'
          else '%s: the card saved in slot %s is no longer theirs, and none is left, so an auto squad plays' end,
        member.display_name, lost.slot)) order by member.display_name, lost.slot), '[]'::jsonb)
      from saved lost
      join members member on member.user_id = lost.user_id
      where not lost.kept and exists (select 1 from cards where cards.user_id = lost.user_id))
  into v_entrants, v_warnings
  from members
  where exists (select 1 from cards where cards.user_id = members.user_id);

  return jsonb_build_object('entrants', v_entrants, 'warnings', v_warnings);
end $$;
revoke all on function kut._mm_field(uuid, timestamptz) from public, anon, authenticated;

-- The club-break gate (§44.1): the football week before p_week_start had a
-- published session. A cancelled session is not published.
create function kut._mm_club_played(p_week_start date)
returns boolean language sql stable security definer set search_path = kut, pg_catalog as $$
  select exists (
    select 1 from kut.match_sessions session
    where session.status = 'published'
      and session.session_date between p_week_start - 7 and p_week_start - 1)
$$;
revoke all on function kut._mm_club_played(date) from public, anon, authenticated;

-- The lock step for one tournament: the gates, then the field as it stands,
-- the simulation and every stored result, in one go.
create function kut._mm_lock_tournament(p_tournament_id uuid)
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
    reveal_at)
  select p_tournament_id, 1, (bye->>'pairing')::smallint, true, (bye->>'userId')::uuid, 0, (bye->>'userId')::uuid,
    kut._mm_reveal_at(v_tournament.lock_at, 1)
  from jsonb_array_elements(v_result->'byes') bye;

  insert into kut.midweek_matches (tournament_id, round, pairing, bye, side_0_user_id, side_1_user_id,
    side_0_goals, side_1_goals, side_0_penalties, side_1_penalties, winner_side, winner_user_id,
    win_chance_ppm, side_0_day_rolls_ppm, side_1_day_rolls_ppm, reveal_at)
  select p_tournament_id, (played->>'round')::smallint, (played->>'pairing')::smallint, false,
    (played#>>'{userIds,0}')::uuid, (played#>>'{userIds,1}')::uuid,
    (played#>>'{outcome,goals,0}')::smallint, (played#>>'{outcome,goals,1}')::smallint,
    (played#>>'{outcome,penalties,0}')::smallint, (played#>>'{outcome,penalties,1}')::smallint,
    (played#>>'{outcome,winnerSide}')::smallint,
    (played->'userIds'->>((played#>>'{outcome,winnerSide}')::int))::uuid,
    (played#>>'{outcome,winChancePpm}')::int,
    array(select jsonb_array_elements_text(played#>'{outcome,dayRollsPpm,0}')::int),
    array(select jsonb_array_elements_text(played#>'{outcome,dayRollsPpm,1}')::int),
    kut._mm_reveal_at(v_tournament.lock_at, (played->>'round')::int)
  from jsonb_array_elements(v_result->'matches') played;

  insert into kut.midweek_match_events (match_id, seq, kind, side, minute, penalty_round, creator_slot, shooter_slot,
    defender_slot, kicker_slot, keeper_slot, chance_type, outcome, p_goal_ppm)
  select stored.id, (event.ord - 1)::smallint, event.value->>'kind', (event.value->>'side')::smallint,
    (event.value->>'minute')::smallint,
    case when event.value->>'kind' = 'penalty' then (event.value->>'round')::smallint end,
    (event.value->>'creator')::smallint, (event.value->>'shooter')::smallint,
    (event.value->>'defender')::smallint, (event.value->>'kicker')::smallint,
    case when event.value->>'kind' = 'penalty' then (event.value->>'keeper')::smallint end,
    event.value->>'chanceType', event.value->>'outcome', (event.value->>'pGoalPpm')::int
  from jsonb_array_elements(v_result->'matches') played
  join kut.midweek_matches stored
    on stored.tournament_id = p_tournament_id
   and stored.round = (played->>'round')::int and stored.pairing = (played->>'pairing')::int
  cross join lateral jsonb_array_elements(played#>'{outcome,events}') with ordinality as event(value, ord);

  update kut.midweek_tournaments
  set status = 'simulated', rounds = v_rounds,
    final_reveal_at = kut._mm_reveal_at(v_tournament.lock_at, v_rounds), updated_at = now()
  where id = p_tournament_id;
  return 'simulated';
end $$;
revoke all on function kut._mm_lock_tournament(uuid) from public, anon, authenticated;

-- The pay step for one tournament: once the final is revealed, publish the
-- seed and complete the week. The payout migration adds the coins here.
create function kut._mm_complete_tournament(p_tournament_id uuid)
returns text language plpgsql security definer set search_path = kut, pg_catalog as $$
declare v_tournament kut.midweek_tournaments%rowtype;
begin
  select * into v_tournament from kut.midweek_tournaments where id = p_tournament_id for update;
  if not found or v_tournament.status <> 'simulated' or v_tournament.final_reveal_at > now() then
    return 'not_due';
  end if;
  update kut.midweek_tournaments
  set status = 'complete', updated_at = now(),
    seed = (select seed from kut.midweek_tournament_secrets where tournament_id = p_tournament_id)
  where id = p_tournament_id;
  return 'complete';
end $$;
revoke all on function kut._mm_complete_tournament(uuid) from public, anon, authenticated;

-- The first ISO Monday whose lock is still ahead and that has no tournament
-- yet, so a voided or skipped week is never run again.
create function kut._mm_next_week()
returns date language plpgsql stable security definer set search_path = kut, pg_catalog as $$
declare v_week date := date_trunc('week', (now() at time zone 'Europe/Amsterdam')::date)::date - 7;
begin
  while kut._mm_lock_at(v_week) <= now()
    or exists (select 1 from kut.midweek_tournaments where week_start = v_week) loop
    v_week := v_week + 7;
  end loop;
  return v_week;
end $$;
revoke all on function kut._mm_next_week() from public, anon, authenticated;

-- The open step: while the switch is on and no tournament is open or
-- simulated, create the next week with a fresh secret seed and its published
-- hash. Two callers racing insert the same week; the unique week_start lets
-- one through.
create function kut._mm_open_next()
returns uuid language plpgsql security definer set search_path = kut, pg_catalog as $$
declare v_week date; v_seed text; v_id uuid;
begin
  if not coalesce((select enabled from kut.midweek_config), false) then return null; end if;
  if exists (select 1 from kut.midweek_tournaments where status in ('open', 'simulated')) then return null; end if;

  v_week := kut._mm_next_week();
  -- 32 bytes from two version-4 UUIDs (pg_strong_random, 244 random bits),
  -- hashed so the seed carries no fixed version nibbles.
  v_seed := encode(sha256(convert_to(gen_random_uuid()::text || gen_random_uuid()::text, 'UTF8')), 'hex');
  insert into kut.midweek_tournaments (week_start, lock_at, seed_hash)
  values (v_week, kut._mm_lock_at(v_week), encode(sha256(decode(v_seed, 'hex')), 'hex'))
  on conflict (week_start) do nothing
  returning id into v_id;
  if v_id is not null then
    insert into kut.midweek_tournament_secrets (tournament_id, seed) values (v_id, v_seed);
  end if;
  return v_id;
end $$;
revoke all on function kut._mm_open_next() from public, anon, authenticated;

-- The lazy worker (§44.11, ADR-061), modelled on finalize_session_surveys:
-- lock what is due, complete what is revealed, then open the next week.
-- Claims skip rows another call holds, so concurrent calls do each piece of
-- work once. save_midweek_squad holds the open tournament FOR SHARE, so a save
-- still in flight at the lock makes this call skip the row, and the next call
-- sees the save. One tournament's failure is recorded and left for the next
-- call.
create function kut.run_midweek_due(p_batch_limit integer default 5)
returns jsonb language plpgsql security definer set search_path = kut, pg_catalog as $$
declare v_job bigint; v_row record; v_locked integer := 0; v_completed integer := 0; v_opened integer := 0;
begin
  if coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'service role required' using errcode = '42501';
  end if;
  if p_batch_limit is null or p_batch_limit not between 1 and 100 then
    raise exception 'batch limit must be 1..100' using errcode = '22023';
  end if;
  insert into kut.midweek_jobs default values returning id into v_job;

  for v_row in
    select id from kut.midweek_tournaments where status = 'open' and lock_at <= now()
    order by lock_at for update skip locked limit p_batch_limit
  loop
    begin
      if kut._mm_lock_tournament(v_row.id) <> 'not_due' then v_locked := v_locked + 1; end if;
    exception when others then
      update kut.midweek_jobs set error_text = concat_ws(E'\n', error_text, format('lock %s: %s', v_row.id, sqlerrm))
      where id = v_job;
    end;
  end loop;

  for v_row in
    select id from kut.midweek_tournaments where status = 'simulated' and final_reveal_at <= now()
    order by final_reveal_at for update skip locked limit p_batch_limit
  loop
    begin
      if kut._mm_complete_tournament(v_row.id) = 'complete' then v_completed := v_completed + 1; end if;
    exception when others then
      update kut.midweek_jobs set error_text = concat_ws(E'\n', error_text, format('complete %s: %s', v_row.id, sqlerrm))
      where id = v_job;
    end;
  end loop;

  begin
    if kut._mm_open_next() is not null then v_opened := 1; end if;
  exception when others then
    update kut.midweek_jobs set error_text = concat_ws(E'\n', error_text, format('open: %s', sqlerrm)) where id = v_job;
  end;

  update kut.midweek_jobs
  set finished_at = now(), locked_count = v_locked, completed_count = v_completed, opened_count = v_opened
  where id = v_job;
  return jsonb_build_object('locked', v_locked, 'completed', v_completed, 'opened', v_opened);
end $$;
revoke all on function kut.run_midweek_due(integer) from public, anon, authenticated;
grant execute on function kut.run_midweek_due(integer) to service_role;

-- 5. Reveal projections ----------------------------------------------------------
-- Definer views gated on kut.is_active_member() (ADR-079) and on time (§44.9):
-- a denied caller, or a moment before the reveal, reads zero rows. Nothing of
-- a void week is shown. They call no _mm_ function, which members cannot
-- execute; the reveal times are stored on the rows. Columns only ever append.

-- Every tournament, as before, with its champion appended once the final is
-- revealed (HANDOFF open question 3, owner decision D4).
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
  champion.display_name as champion_name
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
  'ADR-089, ADR-095: every Midweek Madness tournament (status, skip or void reason, reveal times, the seed only once complete) and its champion once the final is revealed. Gated on kut.is_active_member() (ADR-079).';

-- Each revealed pairing: a match, or a round-1 bye (bye = true, no side 1).
-- Goals are per side, side 0 first; penalties only after a draw.
create view kut.midweek_matches_public
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
  played.side_0_goals,
  played.side_1_goals,
  played.side_0_penalties,
  played.side_1_penalties,
  played.winner_side,
  played.winner_user_id,
  played.win_chance_ppm,
  played.side_0_day_rolls_ppm,
  played.side_1_day_rolls_ppm,
  played.reveal_at
from kut.midweek_matches played
join kut.midweek_tournaments tournament on tournament.id = played.tournament_id
join kut.profiles side_0 on side_0.id = played.side_0_user_id
left join kut.profiles side_1 on side_1.id = played.side_1_user_id
where kut.is_active_member()
  and tournament.status in ('simulated', 'complete')
  and played.reveal_at <= now();

comment on view kut.midweek_matches_public is
  'ADR-095: revealed Midweek Madness pairings, byes included, with goals and penalties per side, the pre-match win chance and each card''s day roll. Gated on kut.is_active_member() (ADR-079) and on reveal_at.';

-- The events of each revealed match, in the engine's order.
create view kut.midweek_events_public
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
  event.p_goal_ppm
from kut.midweek_match_events event
join kut.midweek_matches played on played.id = event.match_id
join kut.midweek_tournaments tournament on tournament.id = played.tournament_id
where kut.is_active_member()
  and tournament.status in ('simulated', 'complete')
  and played.reveal_at <= now();

comment on view kut.midweek_events_public is
  'ADR-095: the events of revealed Midweek Madness matches (chances, penalty kicks, a settling draw), engine slots 0-4. Gated on kut.is_active_member() (ADR-079) and on reveal_at.';

-- Every entered card with its lock-time snapshot and week-long factors, from
-- round 1's reveal (ADR-091). Picks and owner counts appear only once the week
-- is complete (owner decision D3), and an owner count below three never does.
create view kut.midweek_entries_public
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
  card.form_roll_ppm,
  card.pick_factor_ppm,
  card.fitness_ppm,
  card.handicap_ppm,
  card.power_ppm,
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
where kut.is_active_member()
  and tournament.status in ('simulated', 'complete')
  and exists (
    select 1 from kut.midweek_matches first_round
    where first_round.tournament_id = entry.tournament_id and first_round.round = 1
      and first_round.reveal_at <= now());

comment on view kut.midweek_entries_public is
  'ADR-091, ADR-095: every entered Midweek Madness card (engine slots 0-4) with its lock-time OVR, archetype, injury flag and factors, from round 1''s reveal. Picks and owner counts only once complete; owners null below three. Gated on kut.is_active_member() (ADR-079).';

-- Pick shares once the week is complete (§44.9). An owner count below three is
-- null, and a Player nobody picked appears only when at least three own it, so
-- no row hints that one or two members hold a Player.
create view kut.midweek_pick_shares_public
with (security_invoker = false, security_barrier = true)
as
select
  share.tournament_id,
  tournament.week_start,
  share.player_id,
  player.display_name as player_name,
  player.photo_path,
  share.picks,
  case when share.owners >= 3 then share.owners end as owners,
  share.pick_factor_ppm
from kut.midweek_pick_shares share
join kut.midweek_tournaments tournament on tournament.id = share.tournament_id
join kut.players player on player.id = share.player_id
where kut.is_active_member()
  and tournament.status = 'complete'
  and (share.picks > 0 or share.owners >= 3);

comment on view kut.midweek_pick_shares_public is
  'ADR-091, ADR-095: Midweek Madness pick shares of a complete week. Owner counts below three are null; unpicked Players owned by fewer than three are left out. Gated on kut.is_active_member() (ADR-079).';

-- The admin page's week at a glance: the switch, the latest tournament, how
-- many squads are saved and members opted out, and the worker's last run.
create view kut.midweek_admin_overview
with (security_invoker = false, security_barrier = true)
as
select
  config.enabled,
  config.updated_at as switched_at,
  tournament.id as tournament_id,
  tournament.week_start,
  tournament.status,
  tournament.lock_at,
  tournament.final_reveal_at,
  tournament.seed_hash,
  (select count(*)::int from kut.midweek_squads squad where squad.tournament_id = tournament.id) as squads_saved,
  (select count(*)::int from kut.midweek_opt_outs) as opted_out,
  last_job.started_at as last_run_at,
  last_job.error_text as last_run_error
from kut.midweek_config config
left join lateral (
  select * from kut.midweek_tournaments order by week_start desc limit 1
) tournament on true
left join lateral (
  select * from kut.midweek_jobs order by id desc limit 1
) last_job on true
where kut.is_admin();

comment on view kut.midweek_admin_overview is
  'ADR-095: the Midweek Madness switch, the latest tournament, saved-squad and opt-out counts, and the worker''s last run. Admins only (kut.is_admin()).';

revoke all on kut.midweek_matches_public, kut.midweek_events_public, kut.midweek_entries_public,
  kut.midweek_pick_shares_public, kut.midweek_admin_overview
  from public, anon;
grant select on kut.midweek_matches_public, kut.midweek_events_public, kut.midweek_entries_public,
  kut.midweek_pick_shares_public, kut.midweek_admin_overview
  to authenticated, service_role;

-- 6. Admin controls (§44.8) ---------------------------------------------------------

-- The launch and pause switch. Paused, no new tournament opens; one already
-- open still plays unless voided.
create function kut.admin_set_midweek_enabled(p_enabled boolean)
returns jsonb language plpgsql security definer set search_path = kut, pg_catalog as $$
begin
  if not kut.is_admin() then raise exception 'admin role required' using errcode = '42501'; end if;
  if p_enabled is null then raise exception 'say whether Midweek Madness runs' using errcode = '22023'; end if;
  update kut.midweek_config set enabled = p_enabled, updated_at = now(), updated_by = auth.uid();
  return jsonb_build_object('enabled', p_enabled);
end $$;
revoke all on function kut.admin_set_midweek_enabled(boolean) from public, anon;
grant execute on function kut.admin_set_midweek_enabled(boolean) to authenticated, service_role;

-- Voids a week before it is paid: its results disappear and nobody is paid.
-- It never recomputes, and the week never runs again. After payout,
-- corrections go through admin_adjust_wallet.
create function kut.admin_void_midweek(p_tournament_id uuid, p_note text)
returns jsonb language plpgsql security definer set search_path = kut, pg_catalog as $$
declare v_note text := btrim(p_note); v_status text;
begin
  if not kut.is_admin() then raise exception 'admin role required' using errcode = '42501'; end if;
  if v_note is null or char_length(v_note) not between 3 and 200 then
    raise exception 'give a reason of 3 to 200 characters; members read it' using errcode = '22023';
  end if;
  select status into v_status from kut.midweek_tournaments where id = p_tournament_id for update;
  if not found then raise exception 'no such Midweek tournament' using errcode = 'P0002'; end if;
  if v_status = 'complete' then
    raise exception 'this week has been paid, so it cannot be voided' using errcode = 'P0001';
  elsif v_status not in ('open', 'simulated') then
    raise exception 'this week did not run, so there is nothing to void' using errcode = 'P0001';
  end if;
  update kut.midweek_tournaments
  set status = 'void', status_reason = 'admin_void', void_note = v_note,
    voided_at = now(), voided_by = auth.uid(), updated_at = now()
  where id = p_tournament_id;
  return jsonb_build_object('tournament_id', p_tournament_id, 'status', 'void');
end $$;
revoke all on function kut.admin_void_midweek(uuid, text) from public, anon;
grant execute on function kut.admin_void_midweek(uuid, text) to authenticated, service_role;

-- Runs the engine on the squads saved right now plus auto squads, with a
-- throwaway seed, and writes nothing. With no open tournament everyone gets an
-- auto squad. The result is what the admin page shows (HANDOFF "Admin"): the
-- field, who would be auto, every pairing by round, the champion, and
-- warnings, including the gate that would skip the week at the lock.
create function kut.admin_midweek_rehearsal()
returns jsonb language plpgsql security definer set search_path = kut, pg_catalog as $$
declare
  v_tournament kut.midweek_tournaments%rowtype;
  v_week date; v_lock timestamptz; v_field jsonb; v_result jsonb; v_names jsonb; v_seed text;
  v_warnings jsonb; v_would_skip text; v_count integer;
begin
  if not kut.is_admin() then raise exception 'admin role required' using errcode = '42501'; end if;

  select * into v_tournament from kut.midweek_tournaments where status = 'open' order by week_start limit 1;
  v_week := coalesce(v_tournament.week_start, kut._mm_next_week());
  v_lock := coalesce(v_tournament.lock_at, kut._mm_lock_at(v_week));
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
        'reveal_at', kut._mm_reveal_at(v_lock, round_no),
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
          ) pairings)
      ) order by round_no), '[]'::jsonb)
      from generate_series(1, coalesce((v_result->>'rounds')::int, 0)) round_no),
    'champion', case when v_result->>'status' = 'simulated' then jsonb_build_object(
      'user_id', v_result->'championUserId', 'name', v_names->>(v_result->>'championUserId')) end,
    'warnings', v_warnings);
end $$;
revoke all on function kut.admin_midweek_rehearsal() from public, anon;
grant execute on function kut.admin_midweek_rehearsal() to authenticated, service_role;

-- Every engine and internal function stays out of members' reach: the worker,
-- the admin functions and the views call them.
do $$ declare v_fn regprocedure; begin
  for v_fn in
    select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'kut' and p.proname like '\_mm\_%'
  loop
    execute format('revoke all on function %s from public, anon, authenticated', v_fn);
  end loop;
end $$;
