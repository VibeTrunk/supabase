-- Club Value v2 -- a transparent sum a member can reconstruct by hand.
-- See ADR-041.
--
-- Old model (ADR-030 body): club_value = wallet_balance
--   + sum(market_reference_value(edition, discard)) over unburned cards, where
--   reference value is a median of >=5 recent sales clamped to [discard,
--   discard*6], else discard*1.5. It depended on invisible sale history and a
--   piecewise clamp, so nobody could explain their own number.
--
-- New model:
--   club_value = coins
--              + owned_cards_value      -- SUM(discard_value) over unburned owned cards
--              + personal_card_bonus    -- 4 * discard-equivalent of the member's
--                                          linked player's Live card (0 if unlinked)
--
--   discard_value(card)      = round(10 * 1.08^(OVR-30) * special_multiplier)
--   personal_card_base_value = round(10 * 1.08^(linked_player.live_ovr - 30))
--   personal_card_bonus      = 4 * personal_card_base_value
--
-- No linked player (profiles.player_id is null) -> bonus 0. A linked player
-- that exists but has no active-season rating row yet -> the 30-OVR floor
-- (base value 10, bonus 40), matching kut.player_directory's coalesce(...,30).
--
-- W = 4: at OVR 50/60/70 the base value is ~47/101/217, so the personal-card
-- bonus is ~188/404/868 -- a meaningful attendance-driven personal floor that
-- still sits below an active collector's owned-card subtotal, so collecting
-- keeps mattering.
--
-- kut.market_reference_value is NOT dropped -- it still backs kut.get_listing_bounds
-- for market listing price bands. It is simply no longer part of Club Value.
--
-- Both objects are read-only projections; the server-authoritative economy
-- functions remain the only way to change cards, wallets, or market history.
--
-- Tier: data-changing (ADR-032) -- it changes a published economy formula and
-- the leaderboard ordering. Fresh backup immediately before the hosted push.
--
-- Rollback: restore the 20260901000000_admin_manage_accounts_and_leaderboard.sql
-- body of kut.club_value_leaderboard and the 20260817010000 body of
-- kut.my_club_value.

-- Shared discard-value expression, inlined the same way kut.my_collection_cards
-- (20260830000000) and kut.club_value_leaderboard (20260901000000) inline it.

-- my_club_value renames card_value -> owned_cards_value and adds columns, which
-- `create or replace view` cannot do (it only appends), so drop + recreate.
-- club_value_leaderboard keeps its exact column list, so a replace is fine.
drop view if exists kut.my_club_value;
create view kut.my_club_value
with (security_invoker = false, security_barrier = true)
as
with owned as (
  select
    card.owner_id,
    edition.player_id,
    round(
      10 * power(1.08::numeric, coalesce(edition.snapshot_ovr, state.live_ovr, 30) - 30)
      * case when edition.is_live then 1 else coalesce(edition.special_discard_multiplier, 1) end
    )::bigint as discard_value
  from kut.user_cards card
  join kut.card_editions edition on edition.id = card.edition_id
  left join kut.seasons active_season on active_season.is_active
  left join kut.player_season_state state
    on state.player_id = edition.player_id and state.season_id = active_season.id
  where card.burned_at is null
)
select
  profile.display_name,
  coalesce(wallet.balance, 0)::bigint as wallet_balance,
  count(owned.discard_value)::integer as card_count,
  count(distinct owned.player_id)::integer as unique_player_count,
  coalesce(sum(owned.discard_value), 0)::bigint as owned_cards_value,
  4::integer as personal_card_weight,
  personal.player_name as personal_card_player_name,
  personal.slug as personal_card_player_slug,
  coalesce(personal.live_ovr, 0)::integer as personal_card_ovr,
  coalesce(personal.base_value, 0)::bigint as personal_card_base_value,
  (coalesce(personal.base_value, 0) * 4)::bigint as personal_card_bonus,
  (
    coalesce(wallet.balance, 0)
    + coalesce(sum(owned.discard_value), 0)
    + coalesce(personal.base_value, 0) * 4
  )::bigint as club_value
from kut.profiles profile
left join kut.wallets wallet on wallet.user_id = profile.id
left join owned on owned.owner_id = profile.id
left join lateral (
  select
    player.display_name as player_name,
    player.slug,
    coalesce(pstate.live_ovr, 30) as live_ovr,
    round(10 * power(1.08::numeric, coalesce(pstate.live_ovr, 30) - 30))::bigint as base_value
  from kut.players player
  left join kut.seasons s on s.is_active
  left join kut.player_season_state pstate
    on pstate.player_id = player.id and pstate.season_id = s.id
  where player.id = profile.player_id and player.is_active
) personal on true
where profile.id = auth.uid() and not profile.is_disabled
group by profile.id, profile.display_name, wallet.balance,
  personal.player_name, personal.slug, personal.live_ovr, personal.base_value;

create or replace view kut.club_value_leaderboard
with (security_invoker = false, security_barrier = true)
as
with owned as (
  select
    card.owner_id,
    edition.player_id,
    round(
      10 * power(1.08::numeric, coalesce(edition.snapshot_ovr, state.live_ovr, 30) - 30)
      * case when edition.is_live then 1 else coalesce(edition.special_discard_multiplier, 1) end
    )::bigint as discard_value
  from kut.user_cards card
  join kut.card_editions edition on edition.id = card.edition_id
  left join kut.seasons active_season on active_season.is_active
  left join kut.player_season_state state
    on state.player_id = edition.player_id and state.season_id = active_season.id
  where card.burned_at is null
), club_totals as (
  select
    profile.id,
    profile.display_name,
    coalesce(wallet.balance, 0)::bigint as wallet_balance,
    count(owned.discard_value)::integer as card_count,
    count(distinct owned.player_id)::integer as unique_player_count,
    coalesce(sum(owned.discard_value), 0)::bigint as owned_cards_value,
    (coalesce(personal.base_value, 0) * 4)::bigint as personal_card_bonus
  from kut.profiles profile
  left join kut.wallets wallet on wallet.user_id = profile.id
  left join owned on owned.owner_id = profile.id
  left join lateral (
    select round(10 * power(1.08::numeric, coalesce(pstate.live_ovr, 30) - 30))::bigint as base_value
    from kut.players player
    left join kut.seasons s on s.is_active
    left join kut.player_season_state pstate
      on pstate.player_id = player.id and pstate.season_id = s.id
    where player.id = profile.player_id and player.is_active
  ) personal on true
  where not profile.is_disabled and profile.role = 'user'
  group by profile.id, profile.display_name, wallet.balance, personal.base_value
)
select
  rank() over (
    order by (wallet_balance + owned_cards_value + personal_card_bonus) desc, display_name asc
  )::integer as rank,
  display_name,
  display_name || '''s Club' as club_name,
  (wallet_balance + owned_cards_value + personal_card_bonus)::bigint as club_value,
  card_count,
  unique_player_count,
  id = auth.uid() as is_current_user
from club_totals;

revoke all on kut.my_club_value, kut.club_value_leaderboard from public;
grant select on kut.my_club_value, kut.club_value_leaderboard to authenticated, service_role;
