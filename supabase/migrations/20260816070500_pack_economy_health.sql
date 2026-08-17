create view kut.pack_economy_health
with (security_invoker = true, security_barrier = true)
as
with eligible_live_cards as (
  select
    case coalesce(state.rarity_tier, 'common')
      when 'common' then 100::numeric when 'bronze' then 60::numeric
      when 'silver' then 30::numeric when 'gold' then 12::numeric
      when 'holo' then 4::numeric when 'elite' then 1::numeric
    end as weight,
    round(10 * power(1.08::numeric, coalesce(state.live_ovr, 30) - 30))::numeric as discard_value
  from kut.card_editions edition
  join kut.players player on player.id = edition.player_id
  left join kut.seasons active_season on active_season.is_active
  left join kut.player_season_state state on state.player_id = player.id and state.season_id = active_season.id
  where edition.is_live and player.is_active and player.is_collectible
), pack_expectations as (
  select pack.slug, pack.title, pack.price, pack.cards_per_pack,
    count(eligible_live_cards.weight)::integer as eligible_live_count,
    coalesce(sum(eligible_live_cards.weight * eligible_live_cards.discard_value) / nullif(sum(eligible_live_cards.weight), 0), 0) as expected_discard_per_slot
  from kut.pack_definitions pack
  left join eligible_live_cards on true
  where pack.is_active and kut.is_admin()
  group by pack.id, pack.slug, pack.title, pack.price, pack.cards_per_pack
)
select expectation.slug, expectation.title, expectation.price, expectation.cards_per_pack,
  expectation.eligible_live_count,
  round(expectation.expected_discard_per_slot, 2) as expected_discard_per_slot,
  round(expectation.expected_discard_per_slot * expectation.cards_per_pack, 2) as expected_discard_per_pack,
  round((expectation.expected_discard_per_slot * expectation.cards_per_pack) / expectation.price, 4) as expected_discard_return_ratio,
  (select coalesce(sum(balance), 0) from kut.wallets)::bigint as total_coin_supply,
  (select count(*) from kut.pack_openings)::bigint as total_pack_openings,
  (select count(*) from kut.user_cards)::bigint as total_card_copies,
  (select count(*) from kut.user_cards where burned_at is not null)::bigint as total_burned_cards
from pack_expectations expectation;

revoke all on kut.pack_economy_health from public;
grant select on kut.pack_economy_health to authenticated, service_role;
