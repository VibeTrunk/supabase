-- Member self-service (own card photo + own archetype) and the member-facing
-- Player Directory. See ADR-027.
--
-- This migration:
--   1. widens kut.public_live_ratings and kut.my_collection_cards with
--      players.photo_path (append-only via create or replace view);
--   2. adds kut.player_directory -- a member-readable roster projection that
--      LEFT JOINs season state so a brand-new 30-OVR player still lists;
--   3. adds two ownership-gated security-definer RPCs so a member can set the
--      photo / archetype of THEIR OWN linked player only -- there is no direct
--      member write policy on kut.players (RLS keeps writes admin-only), so
--      these RPCs are the sole member write path (mirrors ADR-002/010/025);
--   4. creates the private `player-photos` storage bucket and folder-scoped
--      RLS on storage.objects so a member can only write
--      players/<their-own-linked-player-id>/*.
--
-- set_own_player_archetype re-runs kut._rebuild_season_core because
-- player_season_state.pac..phy are materialised at rebuild time (same reason
-- kut.admin_add_player rebuilds -- ADR-025 / BUILD_SPEC Part 10).
--
-- Rollback (functions/bucket add nothing to existing rows):
--   drop view kut.player_directory;
--   drop function kut.set_own_player_photo(text);
--   drop function kut.set_own_player_archetype(text);
--   drop policy "member reads player photos"   on storage.objects;
--   drop policy "member inserts own player photo" on storage.objects;
--   drop policy "member updates own player photo" on storage.objects;
--   drop policy "member deletes own player photo" on storage.objects;
--   delete from storage.buckets where id = 'player-photos';  -- only if empty
--   then restore the pre-change bodies of kut.public_live_ratings and
--   kut.my_collection_cards captured below.
--
-- Pre-change kut.public_live_ratings body (for rollback):
--   select p.id, p.slug, p.display_name, p.archetype, state.live_ovr,
--     state.pac, state.sho, state.pas, state.dri, state.def, state.phy,
--     state.rarity_tier
--   from kut.players p
--   join kut.player_season_state state on state.player_id = p.id
--   join kut.seasons season on season.id = state.season_id
--   where p.is_active and p.is_collectible and season.is_active;
--
-- Pre-change kut.my_collection_cards body: identical to the statement below
-- minus the trailing `player.photo_path` column.

-- 1a. Widen the member-facing Live Ratings projection with the card photo path.
create or replace view kut.public_live_ratings
with (security_barrier = true)
as
select
  p.id,
  p.slug,
  p.display_name,
  p.archetype,
  state.live_ovr,
  state.pac,
  state.sho,
  state.pas,
  state.dri,
  state.def,
  state.phy,
  state.rarity_tier,
  p.photo_path
from kut.players p
join kut.player_season_state state on state.player_id = p.id
join kut.seasons season on season.id = state.season_id
where p.is_active
  and p.is_collectible
  and season.is_active;

-- Members only (anon was revoked in 20260817030000); re-assert defensively.
revoke all on kut.public_live_ratings from public;
revoke select on kut.public_live_ratings from anon;
grant select on kut.public_live_ratings to authenticated, service_role;

-- 1b. Widen the private collection projection with the card photo path.
create or replace view kut.my_collection_cards
with (security_invoker = true, security_barrier = true)
as
select card.id as card_id, card.edition_id, card.is_tradeable, card.source, card.acquired_at,
  edition.title as edition_title, edition.edition_type, edition.is_live,
  player.id as player_id, player.slug as player_slug, player.display_name, player.archetype,
  coalesce(edition.snapshot_ovr, state.live_ovr, 30) as ovr,
  coalesce(edition.snapshot_pac, state.pac, 30) as pac, coalesce(edition.snapshot_sho, state.sho, 30) as sho,
  coalesce(edition.snapshot_pas, state.pas, 30) as pas, coalesce(edition.snapshot_dri, state.dri, 30) as dri,
  coalesce(edition.snapshot_def, state.def, 30) as def, coalesce(edition.snapshot_phy, state.phy, 30) as phy,
  case when edition.is_live then coalesce(state.rarity_tier, 'common') when coalesce(edition.snapshot_ovr, 30) >= 70 then 'elite' when coalesce(edition.snapshot_ovr, 30) >= 60 then 'holo' when coalesce(edition.snapshot_ovr, 30) >= 50 then 'gold' when coalesce(edition.snapshot_ovr, 30) >= 40 then 'silver' when coalesce(edition.snapshot_ovr, 30) >= 30 then 'bronze' else 'common' end as rarity_tier,
  round(10 * power(1.08::numeric, coalesce(edition.snapshot_ovr, state.live_ovr, 30) - 30) * case when edition.is_live then 1 else coalesce(edition.special_discard_multiplier, 1) end)::bigint as discard_value,
  listing.id as active_listing_id, listing.price as active_listing_price, listing.expires_at as active_listing_expires_at,
  player.photo_path
from kut.user_cards card
join kut.card_editions edition on edition.id = card.edition_id
join kut.players player on player.id = edition.player_id
left join kut.seasons active_season on active_season.is_active
left join kut.player_season_state state on state.player_id = player.id and state.season_id = active_season.id
left join kut.market_listings listing on listing.card_id = card.id and listing.status = 'active' and listing.expires_at > now()
where card.owner_id = auth.uid() and card.burned_at is null;

-- 2. Member-facing Player Directory. LEFT JOIN season state so a player added
-- with no published attendance yet still shows (30 OVR / common). Does not
-- expose who claimed the player.
create view kut.player_directory
with (security_invoker = true, security_barrier = true)
as
select
  p.id,
  p.slug,
  p.display_name,
  p.archetype,
  p.photo_path,
  p.created_at,
  coalesce(s.live_ovr, 30) as live_ovr,
  coalesce(s.pac, 30) as pac,
  coalesce(s.sho, 30) as sho,
  coalesce(s.pas, 30) as pas,
  coalesce(s.dri, 30) as dri,
  coalesce(s.def, 30) as def,
  coalesce(s.phy, 30) as phy,
  coalesce(s.rarity_tier, 'common') as rarity_tier
from kut.players p
left join kut.seasons season on season.is_active
left join kut.player_season_state s on s.player_id = p.id and s.season_id = season.id
where p.is_active and p.is_collectible;

revoke all on kut.player_directory from public;
grant select on kut.player_directory to authenticated, service_role;

-- 3a. Set the caller's own player-card photo path. `null` clears it. A non-null
-- value must be exactly the caller's own canonical object path.
create or replace function kut.set_own_player_photo(p_photo_path text)
returns jsonb
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
declare
  v_player_id uuid;
begin
  select player_id into v_player_id
  from kut.profiles
  where id = auth.uid() and is_disabled = false;

  if v_player_id is null then
    raise exception 'no linked player for this account' using errcode = 'P0001';
  end if;

  if p_photo_path is not null
     and p_photo_path <> format('players/%s/profile.webp', v_player_id) then
    raise exception 'invalid photo path' using errcode = '22023';
  end if;

  update kut.players set photo_path = p_photo_path where id = v_player_id;

  return jsonb_build_object('player_id', v_player_id, 'photo_path', p_photo_path);
end;
$$;

revoke execute on function kut.set_own_player_photo(text) from public, anon;
grant  execute on function kut.set_own_player_photo(text) to authenticated;

-- 3b. Set the caller's own archetype, then rebuild season state so the six
-- attributes re-materialise from the new offsets.
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
     ('all_rounder','speedster','finisher','playmaker','defender','tank') then
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

-- 4a. Private bucket for player-card photos. 5 MiB, raster image types only.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('player-photos', 'player-photos', false, 5242880,
        array['image/webp', 'image/jpeg', 'image/png'])
on conflict (id) do nothing;

-- 4b. Folder-scoped RLS on storage.objects. Object paths are
-- players/<player-uuid>/profile.webp, so (storage.foldername(name))[2] is the
-- player id; a member may write only under their own linked player's folder.
-- Any enabled member may read (the whole app is member-only).
create policy "member reads player photos" on storage.objects
  for select to authenticated
  using (bucket_id = 'player-photos');

create policy "member inserts own player photo" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'player-photos'
    and (storage.foldername(name))[1] = 'players'
    and exists (
      select 1 from kut.profiles
      where id = auth.uid()
        and is_disabled = false
        and player_id::text = (storage.foldername(name))[2]
    )
  );

create policy "member updates own player photo" on storage.objects
  for update to authenticated
  using (
    bucket_id = 'player-photos'
    and (storage.foldername(name))[1] = 'players'
    and exists (
      select 1 from kut.profiles
      where id = auth.uid()
        and is_disabled = false
        and player_id::text = (storage.foldername(name))[2]
    )
  )
  with check (
    bucket_id = 'player-photos'
    and (storage.foldername(name))[1] = 'players'
    and exists (
      select 1 from kut.profiles
      where id = auth.uid()
        and is_disabled = false
        and player_id::text = (storage.foldername(name))[2]
    )
  );

create policy "member deletes own player photo" on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'player-photos'
    and (storage.foldername(name))[1] = 'players'
    and exists (
      select 1 from kut.profiles
      where id = auth.uid()
        and is_disabled = false
        and player_id::text = (storage.foldername(name))[2]
    )
  );
