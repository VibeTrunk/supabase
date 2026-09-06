-- Slice D follow-up: wanted-card market status must use the same public,
-- security-definer projection as the Market screen. Joining user_cards
-- directly hid other members' listed copies under owner-only RLS.
create or replace view kut.my_wanted_cards
with (security_invoker = true, security_barrier = true) as
select w.edition_id, w.state, w.created_at, w.fulfilled_at,
  e.title as edition_title, e.edition_type, e.is_live,
  p.id as player_id, p.slug as player_slug, p.display_name,
  count(card.id)::integer as owned_count,
  listing.lowest_listing_price
from kut.card_wants w
join kut.card_editions e on e.id = w.edition_id
join kut.players p on p.id = e.player_id
left join kut.user_cards card on card.edition_id = w.edition_id
  and card.owner_id = auth.uid() and card.burned_at is null
left join lateral (
  select min(active.price) as lowest_listing_price
  from kut.active_market_listings active
  where active.edition_id = w.edition_id
) listing on true
where w.user_id = auth.uid()
group by w.edition_id, w.state, w.created_at, w.fulfilled_at,
  e.title, e.edition_type, e.is_live, p.id, p.slug, p.display_name,
  listing.lowest_listing_price;

revoke all on kut.my_wanted_cards from public, anon;
grant select on kut.my_wanted_cards to authenticated, service_role;
