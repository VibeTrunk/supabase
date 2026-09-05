-- KB-009 / ADR-054: the club activity feed drops superadmin-driven rows.
--
-- The superadmin account is used for production demos and testing, so its
-- pack openings, sales, trades and listings were showing up in the
-- member-facing feed (Home's activity section, ADR-039) and muddying real
-- club history. This changes only the projection: kut.market_sales,
-- kut.trade_offers, kut.market_listings and kut.pack_openings are untouched,
-- so the underlying ledger and audit history are unaffected and a superadmin
-- row can reappear in the feed the moment that filter is loosened.
--
-- Each unioned branch already joins the profile(s) that generated the row, so
-- this only adds a `role <> 'superadmin'` guard per branch, on whichever side
-- is the "actor":
--   sale     -> exclude if the seller OR the buyer is a superadmin
--   trade    -> exclude if the seller OR the proposer is a superadmin
--   listing  -> exclude if the seller is a superadmin
--   pack     -> exclude if the opener is a superadmin
--   session  -> unchanged; a published session isn't one member's economic
--               activity, so there is no actor role to check
--
-- Tier: additive (ADR-032) -- one `create or replace view`; no table, column
-- or grant changes. Rides the last scheduled backup.
--
-- Rollback DDL: restore kut.activity_feed to its 20260911000000 body (the
-- same five branches, minus the `role <> 'superadmin'` guards).

create or replace view kut.activity_feed
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
where seller.role <> 'superadmin' and buyer.role <> 'superadmin'

union all

select
  'trade'::text,
  offer.resolved_at,
  seller.display_name,
  proposer.display_name,
  player.display_name,
  offer.coins_to_seller,
  null::date,
  null::text
from kut.trade_offers offer
join kut.profiles seller       on seller.id = offer.seller_id
join kut.profiles proposer     on proposer.id = offer.proposer_id
join kut.user_cards card       on card.id = offer.settled_card_id
join kut.card_editions edition on edition.id = card.edition_id
join kut.players player        on player.id = edition.player_id
where offer.status = 'accepted' and offer.resolved_at is not null
  and seller.role <> 'superadmin' and proposer.role <> 'superadmin'

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
  and seller.role <> 'superadmin'

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
where opener.role <> 'superadmin'

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
