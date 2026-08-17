-- Views execute function permissions as the calling member. Keep the internal
-- market-reference helper non-callable by members, and calculate the same
-- bounded reference rule directly inside these security-barrier projections.
create or replace view kut.my_club_value
with (security_invoker = false, security_barrier = true)
as
with recent_sales as (
  select edition_id, count(*) as sale_count,
    percentile_cont(0.5) within group (order by sale_price) as median_sale
  from kut.market_sales
  where sold_at >= now() - interval '14 days'
  group by edition_id
), card_values as (
  select card.owner_id, edition.player_id,
    case when coalesce(recent_sales.sale_count, 0) >= 5 then
      greatest(discard_values.discard_value, least(round(recent_sales.median_sale)::bigint, discard_values.discard_value * 6))
    else round(discard_values.discard_value * 1.5)::bigint end as reference_value
  from kut.user_cards card
  join kut.card_editions edition on edition.id = card.edition_id
  left join kut.seasons active_season on active_season.is_active
  left join kut.player_season_state state on state.player_id = edition.player_id and state.season_id = active_season.id
  left join recent_sales on recent_sales.edition_id = edition.id
  cross join lateral (
    select round(10 * power(1.08::numeric, coalesce(edition.snapshot_ovr, state.live_ovr, 30) - 30) * case when edition.is_live then 1 else coalesce(edition.special_discard_multiplier, 1) end)::bigint as discard_value
  ) discard_values
  where card.burned_at is null
)
select profile.display_name, coalesce(wallet.balance, 0)::bigint as wallet_balance,
  count(card_values.reference_value)::integer as card_count,
  count(distinct card_values.player_id)::integer as unique_player_count,
  coalesce(sum(card_values.reference_value), 0)::bigint as card_value,
  (coalesce(wallet.balance, 0) + coalesce(sum(card_values.reference_value), 0))::bigint as club_value
from kut.profiles profile
left join kut.wallets wallet on wallet.user_id = profile.id
left join card_values on card_values.owner_id = profile.id
where profile.id = auth.uid() and not profile.is_disabled
group by profile.display_name, wallet.balance;

create or replace view kut.club_value_leaderboard
with (security_invoker = false, security_barrier = true)
as
with recent_sales as (
  select edition_id, count(*) as sale_count,
    percentile_cont(0.5) within group (order by sale_price) as median_sale
  from kut.market_sales
  where sold_at >= now() - interval '14 days'
  group by edition_id
), card_values as (
  select card.owner_id, edition.player_id,
    case when coalesce(recent_sales.sale_count, 0) >= 5 then
      greatest(discard_values.discard_value, least(round(recent_sales.median_sale)::bigint, discard_values.discard_value * 6))
    else round(discard_values.discard_value * 1.5)::bigint end as reference_value
  from kut.user_cards card
  join kut.card_editions edition on edition.id = card.edition_id
  left join kut.seasons active_season on active_season.is_active
  left join kut.player_season_state state on state.player_id = edition.player_id and state.season_id = active_season.id
  left join recent_sales on recent_sales.edition_id = edition.id
  cross join lateral (
    select round(10 * power(1.08::numeric, coalesce(edition.snapshot_ovr, state.live_ovr, 30) - 30) * case when edition.is_live then 1 else coalesce(edition.special_discard_multiplier, 1) end)::bigint as discard_value
  ) discard_values
  where card.burned_at is null
), club_totals as (
  select profile.id, profile.display_name, coalesce(wallet.balance, 0)::bigint as wallet_balance,
    count(card_values.reference_value)::integer as card_count,
    count(distinct card_values.player_id)::integer as unique_player_count,
    coalesce(sum(card_values.reference_value), 0)::bigint as card_value
  from kut.profiles profile
  left join kut.wallets wallet on wallet.user_id = profile.id
  left join card_values on card_values.owner_id = profile.id
  where not profile.is_disabled
  group by profile.id, profile.display_name, wallet.balance
)
select rank() over (order by (wallet_balance + card_value) desc, display_name asc)::integer as rank,
  display_name, display_name || '''s Club' as club_name,
  (wallet_balance + card_value)::bigint as club_value,
  card_count, unique_player_count, id = auth.uid() as is_current_user
from club_totals;

revoke all on kut.my_club_value, kut.club_value_leaderboard from public;
grant select on kut.my_club_value, kut.club_value_leaderboard to authenticated, service_role;
