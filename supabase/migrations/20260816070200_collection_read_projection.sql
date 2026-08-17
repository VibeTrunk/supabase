-- A member's collection is intentionally exposed through a narrow, read-only
-- projection. The view selects only the caller's active card copies even when
-- an administrator has broader table-read privileges for operational work.
create view kut.my_collection_cards
with (security_invoker = true, security_barrier = true)
as
select
  card.id as card_id,
  card.edition_id,
  card.is_tradeable,
  card.source,
  card.acquired_at,
  edition.title as edition_title,
  edition.edition_type,
  edition.is_live,
  player.id as player_id,
  player.slug as player_slug,
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
  end as rarity_tier
from kut.user_cards card
join kut.card_editions edition on edition.id = card.edition_id
join kut.players player on player.id = edition.player_id
left join kut.seasons active_season on active_season.is_active
left join kut.player_season_state state
  on state.player_id = player.id
  and state.season_id = active_season.id
where card.owner_id = auth.uid()
  and card.burned_at is null;

revoke all on kut.my_collection_cards from public;
grant select on kut.my_collection_cards to authenticated, service_role;
