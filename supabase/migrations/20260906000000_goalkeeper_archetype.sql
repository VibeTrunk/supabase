-- Batch E1 (tester feedback #4), ADR-036: a seventh archetype, Goalkeeper.
--
-- Goalkeeper reuses the six shared attributes (PAC/SHO/PAS/DRI/DEF/PHY) with
-- its own offset profile -- a shot-stopper: strong DEF/PHY, weak SHO/DRI. It is
-- NOT a distinct stat set (BUILD_SPEC §585). The offsets sum to exactly 0 like
-- the other six (§589 -- no large hidden OVR advantage):
--
--   pac -6   sho -12   pas 0   dri -8   def +14   phy +12   (sum 0)
--
-- Mirrors src/game/rating-engine.ts ARCHETYPE_OFFSETS.goalkeeper and
-- src/game/archetypes.ts ARCHETYPES.
--
-- No player is pre-assigned Goalkeeper here -- it stays opt-in via the existing
-- self-service (kut.set_own_player_archetype) and admin (kut.admin_add_player)
-- RPCs, both of which already run kut._rebuild_season_core. A goalkeeper card is
-- still driven by attendance + goals like every other card; keepers rarely score
-- so their Form stays low, and that is intended -- the card reflects turning up.
--
-- Tier: additive (ADR-032). A widened check constraint, three `create or
-- replace function`s; nothing existing is rewritten and no member row is
-- touched (the rebuild formula change is inert until a Goalkeeper player
-- exists). Rides the last scheduled backup; no fresh pre-push backup required.
--
-- Rollback DDL (safe only while no player has archetype = 'goalkeeper'):
--   alter table kut.players drop constraint players_archetype_check;
--   alter table kut.players add constraint players_archetype_check
--     check (archetype in ('all_rounder','speedster','finisher','playmaker','defender','tank'));
--   -- then `create or replace` kut.admin_add_player, kut.set_own_player_archetype
--   -- and kut._rebuild_season_core from their prior migrations
--   -- (20260829120000, 20260830000000, 20260818000000).

-- 1. Widen the kut.players archetype check ------------------------------------
-- The original constraint (20260816010000) is an unnamed inline check, so it
-- was auto-named. Drop it by lookup, then re-add a named one that includes
-- 'goalkeeper' (same shape as the wallet_ledger.reason widening in Batch D).
do $$
declare
  v_name text;
begin
  select conname into v_name
  from pg_constraint
  where conrelid = 'kut.players'::regclass
    and contype = 'c'
    and pg_get_constraintdef(oid) ilike '%archetype%'
    and pg_get_constraintdef(oid) ilike '%all_rounder%';
  if v_name is null then
    raise exception 'could not locate the kut.players archetype check constraint';
  end if;
  execute format('alter table kut.players drop constraint %I', v_name);
end $$;

alter table kut.players
  add constraint players_archetype_check
  check (archetype in (
    'all_rounder', 'speedster', 'finisher', 'playmaker', 'defender', 'tank',
    'goalkeeper'
  ));

-- 2. admin_add_player: accept 'goalkeeper' ----------------------------------
-- Byte-identical to 20260829120000_admin_add_player.sql except the archetype
-- allow-list gains 'goalkeeper'.
create or replace function kut.admin_add_player(
  p_display_name text,
  p_archetype    text default 'all_rounder',
  p_full_name    text default null
)
returns jsonb
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
declare
  v_display_name text := nullif(btrim(p_display_name), '');
  v_full_name    text := nullif(btrim(coalesce(p_full_name, '')), '');
  v_base_slug    text;
  v_slug         text;
  v_suffix       integer := 1;
  v_player_id    uuid;
  v_season_id    uuid;
begin
  if not kut.is_admin() then
    raise exception 'admin access required' using errcode = '42501';
  end if;

  if v_display_name is null or char_length(v_display_name) > 80 then
    raise exception 'display name must be 1-80 characters' using errcode = '22023';
  end if;

  if p_archetype is null or p_archetype not in
     ('all_rounder','speedster','finisher','playmaker','defender','tank','goalkeeper') then
    raise exception 'invalid archetype: %', p_archetype using errcode = '22023';
  end if;

  v_base_slug := btrim(regexp_replace(lower(v_display_name), '[^a-z0-9]+', '-', 'g'), '-');
  if v_base_slug = '' then
    raise exception 'display name has no usable slug characters' using errcode = '22023';
  end if;

  v_slug := v_base_slug;
  while exists (select 1 from kut.players where slug = v_slug) loop
    v_suffix := v_suffix + 1;
    v_slug := v_base_slug || '-' || v_suffix;
  end loop;

  insert into kut.players (slug, display_name, full_name, archetype)
  values (v_slug, v_display_name, v_full_name, p_archetype)
  returning id into v_player_id;

  insert into kut.card_editions (player_id, edition_type, title, is_live)
  values (v_player_id, 'live', v_display_name || ' Live', true)
  on conflict do nothing;

  -- baseline season-state row via the canonical rebuild so the player shows in
  -- Live Ratings immediately (30 OVR / common until they attend). Idempotent;
  -- skips cleanly with no active season.
  select id into v_season_id from kut.seasons where is_active limit 1;
  if v_season_id is not null then
    perform kut._rebuild_season_core(v_season_id);
  end if;

  return jsonb_build_object(
    'player_id', v_player_id,
    'slug', v_slug,
    'display_name', v_display_name,
    'archetype', p_archetype
  );
end;
$$;

revoke execute on function kut.admin_add_player(text, text, text) from public, anon;
grant  execute on function kut.admin_add_player(text, text, text) to authenticated;

-- 3. set_own_player_archetype: accept 'goalkeeper' ------------------------------
-- Byte-identical to 20260830000000_member_self_service_and_player_directory.sql
-- except the archetype allow-list gains 'goalkeeper'.
create or replace function kut.set_own_player_archetype(p_archetype text)
returns jsonb
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
declare
  v_player_id uuid;
  v_season_id uuid;
begin
  select player_id into v_player_id
  from kut.profiles
  where id = auth.uid() and is_disabled = false;

  if v_player_id is null then
    raise exception 'no linked player for this account' using errcode = 'P0001';
  end if;

  if p_archetype is null or p_archetype not in
     ('all_rounder','speedster','finisher','playmaker','defender','tank','goalkeeper') then
    raise exception 'invalid archetype: %', p_archetype using errcode = '22023';
  end if;

  update kut.players set archetype = p_archetype where id = v_player_id;

  select id into v_season_id from kut.seasons where is_active limit 1;
  if v_season_id is not null then
    perform kut._rebuild_season_core(v_season_id);
  end if;

  return jsonb_build_object('player_id', v_player_id, 'archetype', p_archetype);
end;
$$;

revoke execute on function kut.set_own_player_archetype(text) from public, anon;
grant  execute on function kut.set_own_player_archetype(text) to authenticated;

-- 4. _rebuild_season_core: add the goalkeeper offset arms ----------------------
-- Byte-identical to 20260818000000_initial_tfh_roster_and_august_sessions.sql
-- except each of the six attribute CASE expressions gains a
-- `when 'goalkeeper' then <n>` arm, where the six <n> equal ARCHETYPE_OFFSETS
-- .goalkeeper in src/game/rating-engine.ts. This restates the ADR-024 rating
-- formula -- nothing else in the body changed. It is not called here: it is
-- inert until a player has archetype = 'goalkeeper', at which point the next
-- add-player / archetype-change / publish / correct rebuild picks it up.
create or replace function kut._rebuild_season_core(p_season_id uuid)
returns integer
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
declare
  v_player record;
  v_week record;
  v_activity numeric := 0;
  v_form numeric := 0;
  v_appearances integer;
  v_goals integer;
  v_activity_ovr numeric;
  v_live_ovr integer;
  v_shooting_bonus integer;
  v_rebuilt_count integer := 0;
begin
  if not exists (select 1 from kut.seasons where id = p_season_id) then
    raise exception 'season not found' using errcode = 'P0002';
  end if;

  for v_player in select id, archetype from kut.players loop
    v_activity := 0;
    v_form := 0;
    v_goals := 0;

    for v_week in
      select date_trunc('week', session_date)::date as week_start
      from kut.match_sessions
      where season_id = p_season_id and status = 'published'
      group by date_trunc('week', session_date)::date
      order by week_start
    loop
      select count(*), coalesce(sum(a.goals), 0)
      into v_appearances, v_goals
      from kut.attendance a
      join kut.match_sessions s on s.id = a.session_id
      where a.player_id = v_player.id
        and s.season_id = p_season_id
        and s.status = 'published'
        and date_trunc('week', s.session_date)::date = v_week.week_start;

      v_activity := least(100, greatest(0, v_activity * 0.90 +
        case when v_appearances >= 1 then 14 else 0 end +
        case when v_appearances >= 2 then 3 else 0 end));
      v_form := least(8, greatest(0, v_form * 0.55 +
        1.25 * least(v_goals, 4) + case when v_goals >= 3 then 1 else 0 end));
    end loop;

    v_activity_ovr := 30 + 45 * power(v_activity / 100, 0.80);
    v_live_ovr := least(83, greatest(30, round(v_activity_ovr + round(v_form))::integer));
    v_shooting_bonus := least(8, 2 * greatest(0, v_goals));

    insert into kut.player_season_state (
      player_id, season_id, activity_score, form_score, live_ovr,
      pac, sho, pas, dri, def, phy, rarity_tier, last_week_start
    ) values (
      v_player.id, p_season_id, v_activity, v_form, v_live_ovr,
      least(99, greatest(1, v_live_ovr + case v_player.archetype when 'speedster' then 10 when 'finisher' then 2 when 'defender' then -2 when 'tank' then -8 when 'playmaker' then -2 when 'goalkeeper' then -6 else 0 end)),
      least(99, greatest(1, v_live_ovr + v_shooting_bonus + case v_player.archetype when 'speedster' then -1 when 'finisher' then 10 when 'playmaker' then -2 when 'defender' then -7 when 'tank' then -2 when 'goalkeeper' then -12 else 0 end)),
      least(99, greatest(1, v_live_ovr + case v_player.archetype when 'speedster' then -2 when 'finisher' then -3 when 'playmaker' then 10 when 'defender' then -1 when 'tank' then -2 when 'goalkeeper' then 0 else 0 end)),
      least(99, greatest(1, v_live_ovr + case v_player.archetype when 'speedster' then 4 when 'finisher' then 3 when 'playmaker' then 5 when 'defender' then -4 when 'tank' then -4 when 'goalkeeper' then -8 else 0 end)),
      least(99, greatest(1, v_live_ovr + case v_player.archetype when 'speedster' then -6 when 'finisher' then -8 when 'playmaker' then -6 when 'defender' then 10 when 'tank' then 4 when 'goalkeeper' then 14 else 0 end)),
      least(99, greatest(1, v_live_ovr + case v_player.archetype when 'speedster' then -5 when 'finisher' then -4 when 'playmaker' then -5 when 'defender' then 4 when 'tank' then 12 when 'goalkeeper' then 12 else 0 end)),
      case when v_live_ovr >= 80 then 'elite' when v_live_ovr >= 70 then 'holo' when v_live_ovr >= 60 then 'gold' when v_live_ovr >= 50 then 'silver' when v_live_ovr >= 40 then 'bronze' else 'common' end,
      (select max(date_trunc('week', session_date)::date) from kut.match_sessions where season_id = p_season_id and status = 'published')
    ) on conflict (player_id, season_id) do update set
      activity_score = excluded.activity_score,
      form_score = excluded.form_score,
      live_ovr = excluded.live_ovr,
      pac = excluded.pac, sho = excluded.sho, pas = excluded.pas,
      dri = excluded.dri, def = excluded.def, phy = excluded.phy,
      rarity_tier = excluded.rarity_tier,
      last_week_start = excluded.last_week_start,
      last_rebuilt_at = now();
    v_rebuilt_count := v_rebuilt_count + 1;
  end loop;

  return v_rebuilt_count;
end;
$$;

revoke execute on function kut._rebuild_season_core(uuid) from public, anon, authenticated;
