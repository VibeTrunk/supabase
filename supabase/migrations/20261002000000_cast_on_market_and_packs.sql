-- ADR-086 -- the market and pack openings carry the card's Player, so they can
-- show the plaster cast (ADR-084) by the one rule of ADR-085:
--   injured = is_live and the Player is injured right now.
--
-- Tier: additive, projection-only. Two views gain two trailing columns each,
-- `player_id` and `is_live`, both straight from kut.card_editions. No table is
-- created, altered or written; no grant changes; no DML. Rides the scheduled
-- backup.
--
-- Shape: each body is copied from its latest version (named per view) and the
-- only new text is the two appended select-list items. `create or replace view`
-- can only append columns, and appending last keeps every existing column's
-- name, order and type (the ADR-073 lesson). kut.my_wanted_cards reads
-- kut.active_market_listings, which is why this is `create or replace`, never
-- `drop view`.
--
-- Access is unchanged on both:
--   * kut.active_market_listings stays a definer view gated on
--     kut.is_active_member() (ADR-079). The new columns sit inside the gated
--     body, so the `select *` wrapper exposes them and a denied caller still
--     reads zero rows.
--   * kut.my_pack_opening_results stays `security_invoker = true`, scoped to
--     `opening.user_id = auth.uid()`. It was never one of ADR-079's ten definer
--     projections, so it has no gate to keep, and adding one is an access change
--     outside this slice (ADR-086 records what that leaves open).
--
-- Deploy ordering: Vercel deploys on merge, before the hosted push. The market
-- and pack pages read these views with `select("*")`, so until this lands the
-- new fields are simply absent, which the app reads as "no cast".
--
-- Rollback (optional -- the extra columns are harmless to every reader):
--   `create or replace` cannot drop columns, so each view is dropped and re-run.
--   1. drop view kut.my_wanted_cards;
--      drop view kut.active_market_listings;
--      Re-run the kut.active_market_listings block of
--      20260928000000_active_member_projection_gate.sql (with its revoke/grant),
--      then the whole of 20260920060000_wanted_market_listing_visibility.sql.
--   2. drop view kut.my_pack_opening_results;
--      Re-run block 5 of 20260902000000_starter_reveal_and_rating_snapshots.sql
--      (the view and its revoke/grant).

-- ---------------------------------------------------------------------------
-- kut.active_market_listings
-- Body verbatim from 20260928000000_active_member_projection_gate.sql
-- (itself verbatim from 20260909000000_market_listing_card_art.sql:25-45),
-- plus `edition.player_id, edition.is_live` appended last.
-- ---------------------------------------------------------------------------
create or replace view kut.active_market_listings
with (security_invoker = false, security_barrier = true)
as
select * from (

select listing.id as listing_id, listing.price, listing.listed_at, listing.expires_at,
  card.id as card_id, edition.id as edition_id, player.display_name, player.archetype,
  coalesce(edition.snapshot_ovr, state.live_ovr, 30) as ovr,
  coalesce(edition.snapshot_pac, state.pac, 30) as pac, coalesce(edition.snapshot_sho, state.sho, 30) as sho,
  coalesce(edition.snapshot_pas, state.pas, 30) as pas, coalesce(edition.snapshot_dri, state.dri, 30) as dri,
  coalesce(edition.snapshot_def, state.def, 30) as def, coalesce(edition.snapshot_phy, state.phy, 30) as phy,
  case when edition.is_live then coalesce(state.rarity_tier, 'common') when coalesce(edition.snapshot_ovr, 30) >= 70 then 'elite' when coalesce(edition.snapshot_ovr, 30) >= 60 then 'holo' when coalesce(edition.snapshot_ovr, 30) >= 50 then 'gold' when coalesce(edition.snapshot_ovr, 30) >= 40 then 'silver' when coalesce(edition.snapshot_ovr, 30) >= 30 then 'bronze' else 'common' end as rarity_tier,
  seller.display_name as seller_display_name,
  player.photo_path,
  listing.seller_id,
  edition.player_id,
  edition.is_live
from kut.market_listings listing
join kut.profiles seller on seller.id = listing.seller_id
join kut.user_cards card on card.id = listing.card_id
join kut.card_editions edition on edition.id = card.edition_id
join kut.players player on player.id = edition.player_id
left join kut.seasons active_season on active_season.is_active
left join kut.player_season_state state on state.player_id = player.id and state.season_id = active_season.id
where listing.status = 'active' and listing.expires_at > now() and card.burned_at is null

) gated
where kut.is_active_member();

revoke all on kut.active_market_listings from public, anon;
grant select on kut.active_market_listings to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- kut.my_pack_opening_results
-- Body verbatim from 20260902000000_starter_reveal_and_rating_snapshots.sql
-- block 5, plus `edition.player_id, edition.is_live` appended last.
-- ---------------------------------------------------------------------------
create or replace view kut.my_pack_opening_results
with (security_invoker = true, security_barrier = true)
as
select
  opening.id as opening_id,
  opening.opened_at,
  opening.price_paid,
  pack.slug as pack_slug,
  pack.title as pack_title,
  result.slot,
  card.id as card_id,
  player.display_name,
  player.archetype,
  coalesce(edition.snapshot_ovr, state.live_ovr, 30) as ovr,
  coalesce(edition.snapshot_pac, state.pac, 30) as pac,
  coalesce(edition.snapshot_sho, state.sho, 30) as sho,
  coalesce(edition.snapshot_pas, state.pas, 30) as pas,
  coalesce(edition.snapshot_dri, state.dri, 30) as dri,
  coalesce(edition.snapshot_def, state.def, 30) as def,
  coalesce(edition.snapshot_phy, state.phy, 30) as phy,
  case
    when edition.is_live then coalesce(state.rarity_tier, 'common')
    when coalesce(edition.snapshot_ovr, 30) >= 70 then 'elite'
    when coalesce(edition.snapshot_ovr, 30) >= 60 then 'holo'
    when coalesce(edition.snapshot_ovr, 30) >= 50 then 'gold'
    when coalesce(edition.snapshot_ovr, 30) >= 40 then 'silver'
    when coalesce(edition.snapshot_ovr, 30) >= 30 then 'bronze'
    else 'common'
  end as rarity_tier,
  player.photo_path,
  edition.player_id,
  edition.is_live
from kut.pack_openings opening
join kut.pack_definitions pack on pack.id = opening.pack_id
join kut.pack_opening_cards result on result.opening_id = opening.id
join kut.user_cards card on card.id = result.card_id
join kut.card_editions edition on edition.id = card.edition_id
join kut.players player on player.id = edition.player_id
left join kut.seasons active_season on active_season.is_active
left join kut.player_season_state state
  on state.player_id = player.id
  and state.season_id = active_season.id
where opening.user_id = auth.uid();

revoke all on kut.my_pack_opening_results from public;
grant select on kut.my_pack_opening_results to authenticated, service_role;
