-- Midweek Madness: unclaimed Players' archetypes rotate weekly. BUILD_SPEC
-- §44.2, §44.11, Part L #27; ADR-110 (amends ADR-027 and ADR-099).
--
-- About 80% of the roster has no linked account, so its archetype never moves
-- from the All-rounder default (ADR-027: only the claiming member or an admin
-- changes it). Now the worker's open step gives every unclaimed Player a fresh
-- archetype each week, just before the new week is inserted, so the ADR-099
-- snapshot freezes it for that week:
--
--   * Eligible: `is_active and is_collectible`, and no kut.profiles row links
--     the Player (a disabled account still claims it). Claiming ends the
--     rotation; the member keeps the archetype the Player has then, and the
--     rotation never stamps archetype_changed_at, so their first change stays
--     free (ADR-094).
--   * The draw: each eligible Player draws any of the seven archetypes
--     independently and uniformly, All-rounder and Goalkeeper included (Q8, no
--     smoothing), from the new week's own secret seed under the tag
--     `rotation:<player id>`. Unpredictable before the week opens; checkable
--     once the seed is published at payout against the `seed_hash` published
--     at the open.
--   * Logged: kut.midweek_archetype_rotations holds every change (from, to)
--     per tournament. A Player who draws the archetype they already have is
--     not a change and is not logged.
--   * Card faces follow at once: kut._rebuild_season_core runs once per open
--     that changed anything, as set_own_player_archetype does. OVR does not
--     change (the offsets sum to zero).
--   * One opener at a time: the open step takes a transaction advisory lock
--     and checks again for a running week, so racing worker calls rotate
--     once. A clash on week_start now raises instead of returning null, which
--     rolls the rotation back with the open (the worker records the error).
--
-- The week open at the push keeps its archetypes; the first rotation runs when
-- the worker opens the following week.
--
-- Tier: data-changing (ADR-032). The push itself rewrites no row, but from the
-- next open the worker rewrites kut.players.archetype and the season's stats
-- every week. Fresh cold-verified backup first.
--
-- Rollback DDL:
--   -- re-create kut._mm_open_next from 20261011000000_midweek_evening_timing.sql
--   -- section 5, then:
--   drop function kut._mm_rotate_archetypes(bytea);
--   drop function kut._mm_rotation_archetype(bytea, uuid);
--   drop table kut.midweek_archetype_rotations;
--   -- Rotated archetypes stay as they are; each row's from_archetype restores one.

-- 1. The log ------------------------------------------------------------------------
create table kut.midweek_archetype_rotations (
  tournament_id uuid not null references kut.midweek_tournaments(id) on delete cascade,
  player_id uuid not null references kut.players(id) on delete cascade,
  from_archetype text not null check (from_archetype in
    ('all_rounder','speedster','finisher','playmaker','defender','tank','goalkeeper')),
  to_archetype text not null check (to_archetype in
    ('all_rounder','speedster','finisher','playmaker','defender','tank','goalkeeper')),
  rotated_at timestamptz not null default now(),
  primary key (tournament_id, player_id),
  check (from_archetype <> to_archetype)
);

comment on table kut.midweek_archetype_rotations is
  'ADR-110: each unclaimed Player''s archetype change made when the Midweek tournament opened, '
  'drawn from that tournament''s seed. The tournament''s snapshot holds the result.';

alter table kut.midweek_archetype_rotations enable row level security;
revoke all on kut.midweek_archetype_rotations from public, anon, authenticated;
grant select on kut.midweek_archetype_rotations to service_role;

-- 2. The draw -----------------------------------------------------------------------
-- One Player's archetype for a seed: rng.ts `uniform` over the seven, in
-- src/game/archetypes.ts order, under a tag no other draw uses.
create function kut._mm_rotation_archetype(p_seed bytea, p_player_id uuid)
returns text language sql immutable strict parallel safe set search_path = kut, pg_catalog as $$
  select (array['all_rounder','speedster','finisher','playmaker','defender','tank','goalkeeper'])
    [1 + kut._mm_uniform(p_seed, 'rotation:' || p_player_id::text, 7)]
$$;
revoke all on function kut._mm_rotation_archetype(bytea, uuid) from public, anon, authenticated;

-- 3. The rotation -------------------------------------------------------------------
-- Sets every eligible Player to their draw for the seed and returns the changes
-- as [{playerId, from, to}], ordered by Player. Running it again with the same
-- seed changes nothing. Rebuilds the active season once if anything changed.
create function kut._mm_rotate_archetypes(p_seed bytea)
returns jsonb language plpgsql security definer set search_path = kut, pg_catalog as $$
declare v_changes jsonb; v_season_id uuid;
begin
  if p_seed is null then raise exception 'a rotation needs a seed' using errcode = '22004'; end if;

  with draws as (
    select player.id, player.archetype as from_archetype,
      kut._mm_rotation_archetype(p_seed, player.id) as to_archetype
    from kut.players player
    where player.is_active and player.is_collectible
      and not exists (select 1 from kut.profiles profile where profile.player_id = player.id)
    for update of player
  ),
  changed as (
    update kut.players player
    set archetype = draws.to_archetype
    from draws
    where player.id = draws.id and player.archetype <> draws.to_archetype
    returning player.id, draws.from_archetype, draws.to_archetype
  )
  select coalesce(jsonb_agg(jsonb_build_object('playerId', id, 'from', from_archetype, 'to', to_archetype)
    order by id), '[]'::jsonb)
  into v_changes
  from changed;

  if jsonb_array_length(v_changes) > 0 then
    select id into v_season_id from kut.seasons where is_active limit 1;
    if v_season_id is not null then
      perform kut._rebuild_season_core(v_season_id);
    end if;
  end if;
  return v_changes;
end $$;
revoke all on function kut._mm_rotate_archetypes(bytea) from public, anon, authenticated;

-- 4. The open step rotates first ---------------------------------------------------
-- As in 20261011000000_midweek_evening_timing.sql section 5, except:
--   * one opener at a time, under a transaction advisory lock, checking again
--     for a running week once it holds the lock;
--   * the rotation runs with the new week's seed right before the insert, so
--     the snapshot trigger freezes the rotated archetypes, and is logged
--     against the new week;
--   * no `on conflict do nothing`: a clash on week_start raises, rolling the
--     rotation back with the open.
create or replace function kut._mm_open_next()
returns uuid language plpgsql security definer set search_path = kut, pg_catalog as $$
declare
  v_week date; v_seed text; v_id uuid; v_changes jsonb;
  v_version integer := (kut._mm_config()#>>'{schedule,current}')::int;
begin
  if not coalesce((select enabled from kut.midweek_config), false) then return null; end if;
  if exists (select 1 from kut.midweek_tournaments where status in ('open', 'simulated')) then return null; end if;

  perform pg_advisory_xact_lock(hashtext('kut._mm_open_next'));
  if exists (select 1 from kut.midweek_tournaments where status in ('open', 'simulated')) then return null; end if;

  v_week := kut._mm_next_week();
  -- 32 bytes from two version-4 UUIDs (pg_strong_random, 244 random bits),
  -- hashed so the seed carries no fixed version nibbles.
  v_seed := encode(sha256(convert_to(gen_random_uuid()::text || gen_random_uuid()::text, 'UTF8')), 'hex');
  v_changes := kut._mm_rotate_archetypes(decode(v_seed, 'hex'));

  insert into kut.midweek_tournaments (week_start, lock_at, seed_hash, schedule_version)
  values (v_week, kut._mm_lock_at(v_week, v_version), encode(sha256(decode(v_seed, 'hex')), 'hex'), v_version)
  returning id into v_id;
  insert into kut.midweek_tournament_secrets (tournament_id, seed) values (v_id, v_seed);
  insert into kut.midweek_archetype_rotations (tournament_id, player_id, from_archetype, to_archetype)
  select v_id, (change->>'playerId')::uuid, change->>'from', change->>'to'
  from jsonb_array_elements(v_changes) change;
  return v_id;
end $$;
revoke all on function kut._mm_open_next() from public, anon, authenticated;
