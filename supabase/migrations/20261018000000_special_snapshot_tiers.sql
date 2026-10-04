-- ADR-121 / KB-038: Special rarity is its immutable stored tier, never an OVR ladder.
-- Projection-only; no DML, no issuance, no rating/discard/pack rule changes.
-- Keep every column in place and every existing grant/security mode/member gate.
-- CREATE OR REPLACE preserves ownership and ACLs; explicit options match each source.
-- my_wanted_cards inherits the corrected market rows; trade offered_cards JSON is
-- also corrected (its former Special tier was always Common).
-- Audit: open_pack uses only Live state tiers for weighting and returns opening id,
-- price and replay flags, not rarity. No other RPC returns edition rarity. Live-only
-- directory/riser/Chronicle/economy projections remain unchanged. Midweek results
-- retain their lock-time OVR snapshots; this does not rewrite stored tournaments.
-- Hosted authority: catalogue this exact file in VibeTrunk/supabase before issuance.
-- Never apply a hosted migration from KUT. Local tests use loopback only.
-- Rollback: re-create these four views from the named sources (no drop required).

-- Source: 20260911000000_trade_offers.sql (only the Special tier expression changes).
create or replace view kut.my_collection_cards
with (security_invoker = true, security_barrier = true)
as
select card.id as card_id, card.edition_id, card.source, card.acquired_at,
  edition.title as edition_title, edition.edition_type, edition.is_live,
  player.id as player_id, player.slug as player_slug, player.display_name, player.archetype,
  coalesce(edition.snapshot_ovr, state.live_ovr, 30) as ovr,
  coalesce(edition.snapshot_pac, state.pac, 30) as pac, coalesce(edition.snapshot_sho, state.sho, 30) as sho,
  coalesce(edition.snapshot_pas, state.pas, 30) as pas, coalesce(edition.snapshot_dri, state.dri, 30) as dri,
  coalesce(edition.snapshot_def, state.def, 30) as def, coalesce(edition.snapshot_phy, state.phy, 30) as phy,
  case when edition.is_live then coalesce(state.rarity_tier, 'common') else edition.snapshot_rarity_tier end as rarity_tier,
  round(10 * power(1.08::numeric, coalesce(edition.snapshot_ovr, state.live_ovr, 30) - 30) * case when edition.is_live then 1 else coalesce(edition.special_discard_multiplier, 1) end)::bigint as discard_value,
  listing.id as active_listing_id, listing.price as active_listing_price, listing.expires_at as active_listing_expires_at,
  player.photo_path,
  card.held_by_offer_id
from kut.user_cards card
join kut.card_editions edition on edition.id = card.edition_id
join kut.players player on player.id = edition.player_id
left join kut.seasons active_season on active_season.is_active
left join kut.player_season_state state on state.player_id = player.id and state.season_id = active_season.id
left join kut.market_listings listing on listing.card_id = card.id and listing.status = 'active' and listing.expires_at > now()
where card.owner_id = auth.uid() and card.burned_at is null;

-- Source: 20261010000000_market_listing_discard_value.sql (only the Special tier expression changes).
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
  case when edition.is_live then coalesce(state.rarity_tier, 'common') else edition.snapshot_rarity_tier end as rarity_tier,
  seller.display_name as seller_display_name,
  player.photo_path,
  listing.seller_id,
  edition.player_id,
  edition.is_live,
  case
    when coalesce(edition.snapshot_ovr, state.live_ovr) is not null
      then kut.card_discard_value(card.id)
  end as discard_value
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

-- Source: 20261002000000_cast_on_market_and_packs.sql (only the Special tier expression changes).
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
    else edition.snapshot_rarity_tier
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

-- Source: 20260928000000_active_member_projection_gate.sql (only the Special tier expression changes).
create or replace view kut.my_trade_offers
with (security_invoker = false, security_barrier = true)
as
select * from (

select
  o.id as offer_id,
  o.listing_id,
  o.status,
  o.offered_coins,
  o.created_at,
  o.expires_at,
  o.resolved_at,
  o.coins_to_seller,
  o.coins_burned,
  o.proposer_id,
  o.seller_id,
  (o.proposer_id = auth.uid()) as is_outgoing,
  proposer.display_name as proposer_name,
  seller.display_name as seller_name,
  player.display_name as listing_card_name,
  player.slug as listing_card_slug,
  player.photo_path as listing_card_photo_path,
  listing.price as listing_price,
  listing.status as listing_status,
  coalesce(oc.card_count, 0)::integer as offered_card_count,
  coalesce(oc.cards, '[]'::jsonb) as offered_cards
from kut.trade_offers o
join kut.profiles proposer on proposer.id = o.proposer_id
join kut.profiles seller on seller.id = o.seller_id
join kut.market_listings listing on listing.id = o.listing_id
join kut.user_cards lcard on lcard.id = listing.card_id
join kut.card_editions ledition on ledition.id = lcard.edition_id
join kut.players player on player.id = ledition.player_id
left join lateral (
  select
    count(*) as card_count,
    jsonb_agg(jsonb_build_object(
      'card_id', tc.card_id,
      'display_name', p2.display_name,
      'ovr', coalesce(e2.snapshot_ovr, s2.live_ovr, 30),
      'rarity_tier', case when e2.is_live then coalesce(s2.rarity_tier, 'common') else e2.snapshot_rarity_tier end
    ) order by p2.display_name) as cards
  from kut.trade_offer_cards tc
  join kut.user_cards c2 on c2.id = tc.card_id
  join kut.card_editions e2 on e2.id = c2.edition_id
  join kut.players p2 on p2.id = e2.player_id
  left join kut.seasons as2 on as2.is_active
  left join kut.player_season_state s2 on s2.player_id = p2.id and s2.season_id = as2.id
  where tc.offer_id = o.id
) oc on true
where o.proposer_id = auth.uid() or o.seller_id = auth.uid()

) gated
where kut.is_active_member();
