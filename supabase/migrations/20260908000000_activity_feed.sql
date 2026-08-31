-- Batch E3 (tester feedback #10), ADR-038: a member-wide activity newsfeed.
--
-- One read-only view, kut.activity_feed, unioning four already-persisted event
-- sources. No new write path, no new table, no retention job.
--
--   sale     -> kut.market_sales           (sold_at)
--   listing  -> kut.market_listings        (listed_at; active + unexpired only)
--   pack     -> kut.pack_openings          (opened_at; count only, no card reveal)
--   session  -> kut.match_sessions         (published_at; status = 'published')
--
-- Privacy (the ADR call): a completed-sale row is a NEW disclosure -- until now
-- kut.market_sales was readable only by buyer + seller (RLS). For this small
-- private club the feed shows the seller name, the card, the price AND the
-- buyer name for a sale (the buyer is already visible to the seller via the
-- ADR-019 sale notification). Listings already expose the seller club-wide
-- (ADR-017) -- no change there. Pack openings show the opener + coins spent, not
-- the cards drawn (pack contents stay private).
--
-- The view is `security_invoker = false` (runs as owner, bypassing the
-- underlying RLS) + `security_barrier = true`, granted to `authenticated` --
-- the same controlled-projection pattern as kut.club_value_leaderboard
-- (20260901000000). The underlying tables keep their own RLS for every other
-- code path.
--
-- Retention: none. The page fetches `order by ts desc limit 200` with an
-- optional `?before=<ts>` cursor, so the effective window is ~the last 200
-- events.
--
-- Tier: additive (ADR-032) -- one `create view` + one grant; nothing existing
-- is altered and no row is written. Rides the last scheduled backup.
--
-- Rollback DDL:
--   drop view kut.activity_feed;

create view kut.activity_feed
with (security_invoker = false, security_barrier = true)
as
select
  'sale'::text                    as kind,
  sale.sold_at                    as ts,
  seller.display_name             as actor_name,
  buyer.display_name              as counterparty_name,
  player.display_name             as card_name,
  sale.sale_price                 as amount,
  null::date                      as session_date,
  null::text                      as session_type
from kut.market_sales sale
join kut.profiles seller       on seller.id = sale.seller_id
join kut.profiles buyer        on buyer.id = sale.buyer_id
join kut.card_editions edition on edition.id = sale.edition_id
join kut.players player        on player.id = edition.player_id

union all

select
  'listing'::text,
  listing.listed_at,
  seller.display_name,
  null,
  player.display_name,
  listing.price,
  null::date,
  null::text
from kut.market_listings listing
join kut.user_cards card       on card.id = listing.card_id
join kut.card_editions edition on edition.id = card.edition_id
join kut.players player        on player.id = edition.player_id
join kut.profiles seller       on seller.id = listing.seller_id
where listing.status = 'active' and listing.expires_at > now()

union all

select
  'pack'::text,
  opening.opened_at,
  opener.display_name,
  null,
  null,
  opening.price_paid,
  null::date,
  null::text
from kut.pack_openings opening
join kut.profiles opener on opener.id = opening.user_id

union all

select
  'session'::text,
  session.published_at,
  null,
  null,
  null,
  null::bigint,
  session.session_date,
  session.session_type
from kut.match_sessions session
where session.status = 'published' and session.published_at is not null;

grant select on kut.activity_feed to authenticated, service_role;
