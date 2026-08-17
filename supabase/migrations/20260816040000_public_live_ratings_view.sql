create view kut.public_live_ratings
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
  state.rarity_tier
from kut.players p
join kut.player_season_state state on state.player_id = p.id
join kut.seasons season on season.id = state.season_id
where p.is_active
  and p.is_collectible
  and season.is_active;

revoke all on kut.public_live_ratings from public;
grant usage on schema kut to anon;
grant select on kut.public_live_ratings to anon, authenticated, service_role;
