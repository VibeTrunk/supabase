create or replace view kut.active_market_listings
with (security_invoker = false, security_barrier = true)
as
select listing.id as listing_id, listing.price, listing.listed_at, listing.expires_at,
  card.id as card_id, edition.id as edition_id, player.display_name, player.archetype,
  coalesce(edition.snapshot_ovr, state.live_ovr, 30) as ovr,
  coalesce(edition.snapshot_pac, state.pac, 30) as pac, coalesce(edition.snapshot_sho, state.sho, 30) as sho,
  coalesce(edition.snapshot_pas, state.pas, 30) as pas, coalesce(edition.snapshot_dri, state.dri, 30) as dri,
  coalesce(edition.snapshot_def, state.def, 30) as def, coalesce(edition.snapshot_phy, state.phy, 30) as phy,
  case when edition.is_live then coalesce(state.rarity_tier, 'common') when coalesce(edition.snapshot_ovr, 30) >= 70 then 'elite' when coalesce(edition.snapshot_ovr, 30) >= 60 then 'holo' when coalesce(edition.snapshot_ovr, 30) >= 50 then 'gold' when coalesce(edition.snapshot_ovr, 30) >= 40 then 'silver' when coalesce(edition.snapshot_ovr, 30) >= 30 then 'bronze' else 'common' end as rarity_tier,
  seller.display_name as seller_display_name
from kut.market_listings listing
join kut.profiles seller on seller.id = listing.seller_id
join kut.user_cards card on card.id = listing.card_id
join kut.card_editions edition on edition.id = card.edition_id
join kut.players player on player.id = edition.player_id
left join kut.seasons active_season on active_season.is_active
left join kut.player_season_state state on state.player_id = player.id and state.season_id = active_season.id
where listing.status = 'active' and listing.expires_at > now() and card.burned_at is null;

revoke all on kut.active_market_listings from public;
grant select on kut.active_market_listings to authenticated, service_role;
