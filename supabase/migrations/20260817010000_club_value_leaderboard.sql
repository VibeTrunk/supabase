-- These projections calculate value on read so Live Card ratings and recent
-- qualifying sales are reflected immediately. They are intentionally
-- read-only; the existing server-authoritative economy functions remain the
-- only way to change cards, wallets, or market history.
create view kut.my_club_value
with (security_invoker = false, security_barrier = true)
as
with card_values as (
  select
    card.owner_id,
    edition.player_id,
    kut.market_reference_value(edition.id, kut.card_discard_value(card.id)) as reference_value
  from kut.user_cards card
  join kut.card_editions edition on edition.id = card.edition_id
  where card.burned_at is null
)
select
  profile.display_name,
  coalesce(wallet.balance, 0)::bigint as wallet_balance,
  count(card_values.reference_value)::integer as card_count,
  count(distinct card_values.player_id)::integer as unique_player_count,
  coalesce(sum(card_values.reference_value), 0)::bigint as card_value,
  (coalesce(wallet.balance, 0) + coalesce(sum(card_values.reference_value), 0))::bigint as club_value
from kut.profiles profile
left join kut.wallets wallet on wallet.user_id = profile.id
left join card_values on card_values.owner_id = profile.id
where profile.id = auth.uid() and not profile.is_disabled
group by profile.display_name, wallet.balance;

create view kut.club_value_leaderboard
with (security_invoker = false, security_barrier = true)
as
with card_values as (
  select
    card.owner_id,
    edition.player_id,
    kut.market_reference_value(edition.id, kut.card_discard_value(card.id)) as reference_value
  from kut.user_cards card
  join kut.card_editions edition on edition.id = card.edition_id
  where card.burned_at is null
), club_totals as (
  select
    profile.id,
    profile.display_name,
    coalesce(wallet.balance, 0)::bigint as wallet_balance,
    count(card_values.reference_value)::integer as card_count,
    count(distinct card_values.player_id)::integer as unique_player_count,
    coalesce(sum(card_values.reference_value), 0)::bigint as card_value
  from kut.profiles profile
  left join kut.wallets wallet on wallet.user_id = profile.id
  left join card_values on card_values.owner_id = profile.id
  where not profile.is_disabled
  group by profile.id, profile.display_name, wallet.balance
)
select
  rank() over (order by (wallet_balance + card_value) desc, display_name asc)::integer as rank,
  display_name,
  display_name || '''s Club' as club_name,
  (wallet_balance + card_value)::bigint as club_value,
  card_count,
  unique_player_count,
  id = auth.uid() as is_current_user
from club_totals;

revoke all on kut.my_club_value, kut.club_value_leaderboard from public;
grant select on kut.my_club_value, kut.club_value_leaderboard to authenticated, service_role;
