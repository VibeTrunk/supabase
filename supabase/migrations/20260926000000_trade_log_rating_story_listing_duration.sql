-- Three member-facing readability changes, deployed as one migration.
--
-- ADR-072  a seller chooses a 24- or 72-hour market listing
-- ADR-073  the club log shows a trade's full composition
-- ADR-074  the card page explains what an OVR is made of
--
-- WHY ONE FILE. PRODUCTION_INVARIANTS allows "one migration- or invariant-
-- bearing feature per PR or independently reviewable change slice", and
-- normally that means one feature per PR. These three ship together at the
-- owner's explicit instruction (2026-09-16) so the hosted schema is pushed
-- once rather than three times. The invariant's second limb is satisfied
-- deliberately, not incidentally: each section below is an independently
-- reviewable slice with its own ADR, its own database test file and its own
-- rollback, and the sections touch disjoint objects -- a function, a view
-- replacement, and two new views. Postgres DDL is transactional, so a failure
-- in any section rolls the whole migration back rather than leaving the schema
-- half-applied; that is strictly safer than three sequential pushes.
--
-- Additive tier per docs/OPERATIONS.md: no table is created or altered, no row
-- is backfilled, no data is changed, and no economy or rating formula moves.
-- No Part L invariant is touched.

-- =====================================================================
-- SECTION 1 (ADR-072) -- seller-chosen listing duration
-- =====================================================================
--
-- Until now every listing ran exactly 24 hours: kut.market_listings.expires_at
-- carries `default (now() + interval '24 hours')` and kut.create_listing never
-- set the column, so the default was the only duration available. TFH has many
-- members who do not open the app daily, so a card could lapse unseen.
--
-- Expiry itself is NOT changed. It remains enforced by the `expires_at > now()`
-- predicates in the market_listings RLS policy, kut.active_market_listings,
-- kut.my_collection_cards, kut.activity_feed, kut.buy_listing,
-- kut.propose_trade and kut.prevent_burning_listed_card, plus the
-- opportunistic self-heal in create_listing/buy_listing that flips a lapsed row
-- to status='expired'. There is still no sweeper, which remains the deliberate
-- decision in docs/LAUNCH_PLAN.md ("the sweep is not what enforces expiry").
--
-- Adding a defaulted third parameter would create an OVERLOAD rather than
-- replace the function, leaving the old two-argument entry point callable and
-- permanently 24-hour-only. So the old signature is dropped first, following
-- the ADR-037 precedent for publish_attendance_session. The body starts from
-- the current one in 20260911000000_trade_offers.sql (section 11) so the
-- ADR-042 held_by_offer_id escrow guard and the lazy self-heal survive intact.
-- The new parameter still defaults to 24, so existing two-argument callers stay
-- valid.
--
-- The allowed durations are dual-declared: this allow-list and
-- ECONOMY.listingDurationChoiceHours in src/game/economy.ts.
--
-- Rollback: drop kut.create_listing(uuid, bigint, integer) and recreate the
-- two-argument version from 20260911000000_trade_offers.sql lines 624-663.

drop function if exists kut.create_listing(uuid, bigint);

create or replace function kut.create_listing(
  p_card_id uuid,
  p_price bigint,
  p_duration_hours integer default 24
)
returns jsonb
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
declare
  v_user_id uuid := auth.uid();
  v_card record;
  v_bounds jsonb;
  v_listing_id uuid;
  v_expires_at timestamptz;
begin
  if v_user_id is null then raise exception 'authentication required' using errcode = '42501'; end if;
  if p_price is null or p_price < 1 then raise exception 'listing price must be positive' using errcode = '22023'; end if;
  -- An allow-list, not a range: an arbitrary duration would let a seller park a
  -- card in the listing soft-lock for as long as they liked.
  if p_duration_hours is null or p_duration_hours not in (24, 72) then
    raise exception 'listing duration must be 24 or 72 hours' using errcode = '22023';
  end if;
  perform 1 from kut.profiles where id = v_user_id and not is_disabled for update;
  if not found then raise exception 'active profile not found' using errcode = '42501'; end if;

  select id, held_by_offer_id into v_card from kut.user_cards
  where id = p_card_id and owner_id = v_user_id and burned_at is null for update;
  if not found then raise exception 'card is not eligible for listing' using errcode = 'P0001'; end if;
  if v_card.held_by_offer_id is not null then
    raise exception 'card is committed to a pending trade offer' using errcode = 'P0001';
  end if;
  update kut.market_listings set status = 'expired'
  where card_id = p_card_id and status = 'active' and expires_at <= now();
  if exists (select 1 from kut.market_listings where card_id = p_card_id and status = 'active') then
    raise exception 'card already has an active listing' using errcode = 'P0001';
  end if;

  v_bounds := kut.get_listing_bounds(p_card_id);
  if p_price < (v_bounds ->> 'minimum_price')::bigint or p_price > (v_bounds ->> 'maximum_price')::bigint then
    raise exception 'listing price is outside the current allowed range' using errcode = '22023';
  end if;

  insert into kut.market_listings(card_id, seller_id, price, expires_at)
  values (p_card_id, v_user_id, p_price, now() + make_interval(hours => p_duration_hours))
  returning id, expires_at into v_listing_id, v_expires_at;
  -- Report the row actually written. The previous body returned a hardcoded
  -- `now() + interval '24 hours'` that was never read back from the insert;
  -- with a variable duration that would simply have been wrong.
  return jsonb_build_object(
    'listing_id', v_listing_id,
    'expires_at', v_expires_at,
    'duration_hours', p_duration_hours
  );
end;
$$;

revoke execute on function kut.create_listing(uuid, bigint, integer) from public, anon;
grant execute on function kut.create_listing(uuid, bigint, integer) to authenticated, service_role;

-- =====================================================================
-- SECTION 2 (ADR-073) -- the club log shows a trade's full composition
-- =====================================================================
--
-- An accepted trade logged only the net coins the seller banked and the name of
-- the listed card. When an offer bundled cards plus coins -- or several cards
-- plus coins -- everything except the coin receipt was invisible, so the feed
-- understated what actually changed hands. Two defects, both fixed here in the
-- projection alone; no trade data is rewritten.
--
-- 1. AMOUNT WAS NET ONLY FOR TRADES. Every other branch reports gross
--    (market_sales.sale_price, market_listings.price, pack_openings.price_paid)
--    while the trade branch reported trade_offers.coins_to_seller, which is
--    already 5% lighter than what the proposer actually paid. The trade branch
--    now reports trade_offers.offered_coins, making `amount` mean the same
--    thing in all five branches. Past trades therefore read higher than before;
--    that is a deliberate correction, not a data change -- coins_to_seller and
--    coins_burned are untouched on the row and the seller still sees their real
--    receipt on /market/offers.
--
-- 2. OFFERED CARDS WERE NEVER JOINED. kut.trade_offer_cards existed but the
--    view never touched it, so the cards that went back to the seller could not
--    appear at all. A lateral array_agg supplies their player names.
--
-- The new column is APPENDED. `create or replace view` can add columns only at
-- the end -- never reorder or drop -- which is the same constraint ADR-040 hit
-- when adding photo_path/seller_id, so column order here is load-bearing.
-- All five branches must therefore carry the column, with null::text[] in the
-- four that have no offered cards.
--
-- The view keeps security_invoker = false (owner rights), so the new join
-- raises no RLS question; the feed already discloses both counterparty names
-- and the listed card club-wide, and the offered cards are the other half of
-- the same disclosed transaction.
--
-- Deliberately unchanged: the `status = 'accepted' and resolved_at is not null`
-- guard, both `role <> 'superadmin'` guards (KB-009 / ADR-054), and the rule
-- that an accepted trade is never written to kut.market_sales (Part L
-- invariant #23) -- market_sales is not referenced by the trade branch.
--
-- Rollback: re-run the view body from
-- 20260915000000_activity_feed_excludes_superadmin.sql, which restores both the
-- net amount and the eight-column shape.

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
  null::text                      as session_type,
  null::text[]                    as offered_card_names
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
  offer.offered_coins,
  null::date,
  null::text,
  offered.names
from kut.trade_offers offer
join kut.profiles seller       on seller.id = offer.seller_id
join kut.profiles proposer     on proposer.id = offer.proposer_id
join kut.user_cards card       on card.id = offer.settled_card_id
join kut.card_editions edition on edition.id = card.edition_id
join kut.players player        on player.id = edition.player_id
left join lateral (
  select array_agg(offered_player.display_name order by offered_player.display_name) as names
  from kut.trade_offer_cards offer_card
  join kut.user_cards offered_card       on offered_card.id = offer_card.card_id
  join kut.card_editions offered_edition on offered_edition.id = offered_card.edition_id
  join kut.players offered_player        on offered_player.id = offered_edition.player_id
  where offer_card.offer_id = offer.id
) offered on true
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
  null::text,
  null::text[]
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
  null::text,
  null::text[]
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
  session.session_type,
  null::text[]
from kut.match_sessions session
where session.status = 'published' and session.published_at is not null;

grant select on kut.activity_feed to authenticated, service_role;

-- =====================================================================
-- SECTION 3 (ADR-074) -- the card page explains what an OVR is made of
-- =====================================================================
--
-- A card shows its OVR but never explains it. Attendance, goals and kudos all
-- feed the number and every input is already persisted, yet a member could not
-- see why they were a 62 or where a recent +2 came from. The kudos_awarded
-- notice (ADR-069) explains one session; nothing explained the standing rating.
--
-- NO NEW DATA IS STORED. kut.session_report_results already holds
-- effective_goals, goal_form, kudos_form, session_input and
-- qualified_category_ids per player per session, and kut.player_season_state
-- already holds activity_score and form_score. These are read projections over
-- facts that already exist; they compute no new rating and write nothing.
--
-- HOW THE SPLIT IS DERIVED, AND WHY NOT BY FORMULA. docs/RATING_BALANCE_REVIEW
-- rules that Form is rounded once on the total -- "three separate category
-- awards are not individually rounded and added" -- so a per-line "+N OVR"
-- would not sum to the real figure. The engine computes
--   v_live := least(83, greatest(30, round(v_activity_ovr + floor(v_form + .5))))
-- so the attendance half could be recomputed as 30 + 45*(activity/100)^0.8.
-- It deliberately is NOT. Recomputing risks an off-by-one against the stored
-- live_ovr; instead the bonus is floor(form_score + 0.5) -- the engine's own
-- final rounding -- and the base is live_ovr minus that bonus. Base + bonus
-- then equals the number on the card face BY CONSTRUCTION, including where
-- live_ovr is clamped. is_ovr_capped tells the UI when the 83 ceiling has
-- deflated the base so it can say so.
--
-- DECAY IS EXPRESSED A SECOND TIME HERE. player_form_contributions re-derives
-- the session-age weight (1 / .75 / .5 / .25 / 0) and the age expression from
-- kut._rebuild_season_core (20260920000000_session_reports_rating_v2.sql, the
-- v2 branch). That is a real duplication risk: if the ladder changes in the
-- engine and not here, this view silently lies. It is pinned by
-- supabase/tests/database/rating_breakdown.test.sql, which asserts that the
-- summed weighted_contribution equals player_season_state.form_score for a
-- v2-only fixture under the +8 cap. Change one, run that test.
-- Per ADR-064 the maths is NOT mirrored into TypeScript; these views are the
-- single read path.
--
-- PRIVACY. Both views are security_invoker = true, so the caller's own RLS
-- applies: session_report_results is already gated to finalized surveys by
-- kut.is_survey_finalized (ADR-066), match_sessions to published rows, and
-- players / player_season_state / kudos_categories are member-readable.
-- Neither view may ever join kut.session_kudos, which holds nominator
-- identity, nor kut.session_surveys, whose attendee-only policy caused the
-- KB-013 blackout -- session dates come from match_sessions and category
-- titles from qualified_category_ids, so neither table is needed.
--
-- Rollback: drop both views. Nothing else references them.

create view kut.player_rating_breakdown
with (security_invoker = true, security_barrier = true)
as
select
  state.player_id,
  state.season_id,
  player.slug                                            as player_slug,
  player.display_name,
  state.live_ovr,
  state.form_score,
  state.activity_score,
  floor(state.form_score + 0.5)::integer                 as form_bonus,
  state.live_ovr - floor(state.form_score + 0.5)::integer as attendance_base,
  (state.live_ovr >= 83)                                 as is_ovr_capped
from kut.player_season_state state
join kut.players player on player.id = state.player_id
join kut.seasons season on season.id = state.season_id
where season.is_active;

comment on view kut.player_rating_breakdown is
  'ADR-074: splits a player''s current OVR into its attendance base and its Form bonus. attendance_base + form_bonus = live_ovr by construction; see is_ovr_capped when the 83 ceiling applies.';

create view kut.player_form_contributions
with (security_invoker = true, security_barrier = true)
as
select
  result.player_id,
  result.session_id,
  session.season_id,
  session.session_date,
  session.session_type,
  result.effective_goals,
  result.goal_form,
  result.kudos_form,
  result.session_input,
  age.value                                  as session_age,
  weight.value                               as weight,
  result.session_input * weight.value        as weighted_contribution,
  categories.titles                          as recognized_categories
from kut.session_report_results result
join kut.match_sessions session on session.id = result.session_id
join kut.seasons season on season.id = session.season_id
cross join lateral (
  -- Age in SESSIONS, not weeks: the count of later published v2 sessions,
  -- ordered exactly as _rebuild_season_core orders them. RATING_BALANCE_REVIEW
  -- is explicit that four sessions must never be equated with four weeks.
  select count(*)::integer as value
  from kut.match_sessions later
  where later.season_id = session.season_id
    and later.status = 'published'
    and later.rating_rules_version = 2
    and (later.session_date, later.session_type, later.id)
        > (session.session_date, session.session_type, session.id)
) age
cross join lateral (
  select case age.value
           when 0 then 1.00
           when 1 then 0.75
           when 2 then 0.50
           when 3 then 0.25
           else 0.00
         end::numeric as value
) weight
left join lateral (
  select array_agg(category.title order by category.title) as titles
  from kut.kudos_categories category
  where category.id = any(result.qualified_category_ids)
) categories on true
where season.is_active
  and session.status = 'published'
  and session.rating_rules_version = 2;

comment on view kut.player_form_contributions is
  'ADR-074: the per-session Form inputs behind a player''s current Form score, with the session-age decay weight mirrored from kut._rebuild_season_core. Never joins session_kudos (nominator identity) or session_surveys (KB-013).';

revoke all on kut.player_rating_breakdown from public;
revoke all on kut.player_form_contributions from public;
grant select on kut.player_rating_breakdown to authenticated, service_role;
grant select on kut.player_form_contributions to authenticated, service_role;
