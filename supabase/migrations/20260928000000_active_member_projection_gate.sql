-- KB-017 / ADR-079 -- every member-only definer projection proves an active
-- KUT profile.
--
-- Tier: additive, projection-only. No table is created, altered or written; no
-- grant changes; no DML. Rides the scheduled backup.
--
-- The finding (Supabase Security Advisor). Ten views are
-- `security_invoker = false` and grant SELECT to the shared project's
-- `authenticated` role, deliberately bypassing their source tables' RLS -- but
-- none of them proves the caller is a KUT member. A user authenticated for
-- another VibeTrunk tool in this project, or a disabled KUT account with a
-- still-valid session, could read member-only names, market and activity data,
-- Club Values, ratings and Chronicle results through the Data API. A bounded
-- read disclosure: these are read projections and `anon` has no SELECT.
--
-- Deliberately NOT flipped to `security_invoker = true`. That is the generic
-- remedy and it is wrong here: these are cross-RLS club projections by design,
-- and doing it to kut.chronicle_session_reports is literally KB-013, the live
-- Chronicle blackout. Every view stays definer; a predicate is added instead.
--
-- Shape: each body below is BYTE-IDENTICAL to its source (named per view). The
-- only new text is the `select * from ( ... ) gated where
-- kut.is_active_member()` wrapper. The risk in this migration is transcription
-- across ten bodies and six source files, not semantics, so the bodies are
-- copied rather than edited -- which also means `create or replace view` cannot
-- change the column names, order or types (the ADR-073 lesson), since `select *`
-- is expanded from an unchanged body. kut.is_active_member() references no
-- column, so the planner gates the body with a One-Time Filter and a denied
-- caller never executes it.
--
-- The gate FILTERS; it never raises. src/lib/nav/context.ts:47-52 reads
-- kut.my_trade_offers in the same Promise.all as the profile read, before the
-- disabled-user redirect fires. A disabled member must get zero rows and no
-- error there, or every disabled member's "/" render 500s instead of
-- redirecting to /login.
--
-- Rollback:
--   1. Re-emit the ten bodies WITHOUT the wrapper, as `create or replace view`
--      -- never `drop view`, which would need cascade because kut.my_club_value
--      depends on kut.my_club_value_editions. Sources are named per view below.
--      Restore kut.public_live_ratings to `with (security_barrier = true)` alone.
--   2. drop function kut.is_active_member();
--   Grants are unchanged by this migration, so none need re-granting.
--
-- Operator note: kut.is_active_member() is false for a bare psql session with
-- no JWT and no SET ROLE. An ad-hoc query against these ten views needs
-- `set role service_role;` first, or it reads zero rows.

create or replace function kut.is_active_member()
returns boolean
language sql
stable
security definer
set search_path = kut, pg_catalog
as $fn$
  select coalesce(auth.role(), '') = 'service_role'
      or coalesce(current_setting('role', true), 'none') = 'service_role'
      or exists (
           select 1
           from kut.profiles profile
           where profile.id = auth.uid()
             and not profile.is_disabled
         );
$fn$;

comment on function kut.is_active_member() is
  'KB-017 / ADR-079. True for the service role, and for an authenticated caller holding a kut.profiles row that is not disabled. security definer because kut.profiles RLS lets a member read only their own row, so an invoker-rights probe could never prove a foreign caller has no profile. Never raises: a denied caller must read zero rows, not an error.';

-- Two service-role disjuncts, one per transport. auth.role() is the house idiom
-- (20260920000000:348) and covers a service-key JWT, which carries no sub, so
-- auth.uid() is null and the profile branch would deny. current_setting('role')
-- covers a bare `set role service_role` psql session: entering a SECURITY
-- DEFINER function changes current_user but not the role GUC.
--
-- NOT current_user: inside a definer body that is the function OWNER, so the
-- predicate would be unconditionally true and this migration would ship as a
-- no-op that looks fixed. NOT pg_has_role(session_user,'service_role','member'):
-- session_user is `authenticator` for every PostgREST request, and
-- `authenticator` IS a member of service_role.
--
-- No role filter: admins and superadmins read as members. The superadmin guard
-- in kut.activity_feed (KB-009) and the role='user' filter in
-- kut.club_value_leaderboard scope those views' SUBJECTS, a different question.

revoke execute on function kut.is_active_member() from public, anon;
grant execute on function kut.is_active_member() to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- kut.activity_feed
-- Body verbatim from 20260926000000_trade_log_rating_story_listing_duration.sql:162-260.
-- Both KB-009 `role <> 'superadmin'` guards and the ADR-073 nine-column shape
-- are inside the body, untouched. Five UNION ALL branches gated in one place.
-- ---------------------------------------------------------------------------
create or replace view kut.activity_feed
with (security_invoker = false, security_barrier = true)
as
select * from (

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
where session.status = 'published' and session.published_at is not null

) gated
where kut.is_active_member();

revoke all on kut.activity_feed from public, anon;
grant select on kut.activity_feed to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- kut.active_market_listings
-- Body verbatim from 20260909000000_market_listing_card_art.sql:25-45.
-- ---------------------------------------------------------------------------
create or replace view kut.active_market_listings
with (security_invoker = false, security_barrier = true)
as
select * from (

select listing.id as listing_id, listing.price, listing.listed_at, listing.expires_at,
  card.id as card_id, edition.id as edition_id, player.display_name, player.archetype,
  coalesce(edition.snapshot_ovr, state.live_ovr, 30) as ovr,
  coalesce(edition.snapshot_pac, state.pac, 30) as pac, coalesce(edition.snapshot_sho, state.sho, 30) as sho,
  coalesce(edition.snapshot_pas, state.pas, 30) as pas, coalesce(edition.snapshot_dri, state.dri, 30) as dri,
  coalesce(edition.snapshot_def, state.def, 30) as def, coalesce(edition.snapshot_phy, state.phy, 30) as phy,
  case when edition.is_live then coalesce(state.rarity_tier, 'common') when coalesce(edition.snapshot_ovr, 30) >= 70 then 'elite' when coalesce(edition.snapshot_ovr, 30) >= 60 then 'holo' when coalesce(edition.snapshot_ovr, 30) >= 50 then 'gold' when coalesce(edition.snapshot_ovr, 30) >= 40 then 'silver' when coalesce(edition.snapshot_ovr, 30) >= 30 then 'bronze' else 'common' end as rarity_tier,
  seller.display_name as seller_display_name,
  player.photo_path,
  listing.seller_id
from kut.market_listings listing
join kut.profiles seller on seller.id = listing.seller_id
join kut.user_cards card on card.id = listing.card_id
join kut.card_editions edition on edition.id = card.edition_id
join kut.players player on player.id = edition.player_id
left join kut.seasons active_season on active_season.is_active
left join kut.player_season_state state on state.player_id = player.id and state.season_id = active_season.id
where listing.status = 'active' and listing.expires_at > now() and card.burned_at is null

) gated
where kut.is_active_member();

revoke all on kut.active_market_listings from public, anon;
grant select on kut.active_market_listings to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- kut.my_club_value_editions
-- Body verbatim from 20260917000000_duplicate_club_value.sql:20-41.
-- ---------------------------------------------------------------------------
create or replace view kut.my_club_value_editions
with (security_invoker = false, security_barrier = true)
as
select * from (

with resolved as (
  select c.owner_id, c.edition_id, e.player_id, e.title, e.edition_type, e.is_live,
    case when e.is_live then coalesce(s.live_ovr,30) else e.snapshot_ovr end as ovr,
    round(10 * power(1.08::numeric,
      (case when e.is_live then coalesce(s.live_ovr,30) else e.snapshot_ovr end) - 30)
      * case when e.is_live then 1 else e.special_discard_multiplier end)::bigint as discard_value,
    count(*)::integer as copy_count
  from kut.user_cards c
  join kut.card_editions e on e.id=c.edition_id
  left join kut.seasons active on active.is_active
  left join kut.player_season_state s on s.player_id=e.player_id and s.season_id=active.id
  where c.burned_at is null
  group by c.owner_id,c.edition_id,e.player_id,e.title,e.edition_type,e.is_live,e.snapshot_ovr,
    e.special_discard_multiplier,s.live_ovr
)
select edition_id, player_id, title as edition_title, edition_type, is_live, ovr,
  discard_value, copy_count,
  kut.duplicate_edition_contribution(discard_value,copy_count) as club_value_contribution
from resolved where owner_id=auth.uid()

) gated
where kut.is_active_member();

revoke all on kut.my_club_value_editions from public, anon;
grant select on kut.my_club_value_editions to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- kut.my_club_value_copies
-- Body verbatim from 20260917000000_duplicate_club_value.sql:43-70.
-- ---------------------------------------------------------------------------
create or replace view kut.my_club_value_copies
with (security_invoker = false, security_barrier = true)
as
select * from (

with ranked as (
  select c.id as card_id,c.owner_id,c.edition_id,c.acquired_at,e.title as edition_title,
    p.display_name,p.slug as player_slug,
    case when e.is_live then coalesce(s.live_ovr,30) else e.snapshot_ovr end as ovr,
    round(10 * power(1.08::numeric,
      (case when e.is_live then coalesce(s.live_ovr,30) else e.snapshot_ovr end)-30)
      * case when e.is_live then 1 else e.special_discard_multiplier end)::bigint as discard_value,
    row_number() over(partition by c.owner_id,c.edition_id order by c.acquired_at,c.id)::integer as copy_position,
    count(*) over(partition by c.owner_id,c.edition_id)::integer as copy_count
  from kut.user_cards c
  join kut.card_editions e on e.id=c.edition_id
  join kut.players p on p.id=e.player_id
  left join kut.seasons active on active.is_active
  left join kut.player_season_state s on s.player_id=e.player_id and s.season_id=active.id
  where c.burned_at is null
)
select card_id,edition_id,edition_title,display_name,player_slug,ovr,discard_value,
  copy_position,copy_count,
  case copy_position when 1 then 100 when 2 then 20 when 3 then 5 else 0 end::integer as weight_percent,
  case copy_position when 1 then discard_value when 2 then floor(discard_value*20/100.0)::bigint
    when 3 then floor(discard_value*5/100.0)::bigint else 0 end as club_value_contribution,
  (discard_value
    + kut.duplicate_edition_contribution(discard_value,copy_count-1)
    - kut.duplicate_edition_contribution(discard_value,copy_count))::bigint as club_value_change_if_discarded
from ranked where owner_id=auth.uid()

) gated
where kut.is_active_member();

revoke all on kut.my_club_value_copies from public, anon;
grant select on kut.my_club_value_copies to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- kut.my_club_value
-- Body verbatim from 20260917000000_duplicate_club_value.sql:73-99.
-- Keeps its own `not profile.is_disabled`. Redundant now, but removing it would
-- be an interior edit to a verbatim body and forfeit the mechanical diff.
-- ---------------------------------------------------------------------------
create or replace view kut.my_club_value
with (security_invoker = false, security_barrier = true)
as
select * from (

with owned as (
  select coalesce(sum(club_value_contribution),0)::bigint as owned_cards_value,
    coalesce(sum(copy_count),0)::integer as card_count,
    count(distinct player_id)::integer as unique_player_count
  from kut.my_club_value_editions
)
select profile.display_name,coalesce(wallet.balance,0)::bigint as wallet_balance,
  owned.card_count,owned.unique_player_count,owned.owned_cards_value,
  4::integer as personal_card_weight,personal.player_name as personal_card_player_name,
  personal.slug as personal_card_player_slug,coalesce(personal.live_ovr,0)::integer as personal_card_ovr,
  coalesce(personal.base_value,0)::bigint as personal_card_base_value,
  (coalesce(personal.base_value,0)*4)::bigint as personal_card_bonus,
  (coalesce(wallet.balance,0)+owned.owned_cards_value+coalesce(personal.base_value,0)*4)::bigint as club_value
from kut.profiles profile
cross join owned
left join kut.wallets wallet on wallet.user_id=profile.id
left join lateral (
  select p.display_name as player_name,p.slug,coalesce(s.live_ovr,30) as live_ovr,
    round(10*power(1.08::numeric,coalesce(s.live_ovr,30)-30))::bigint as base_value
  from kut.players p left join kut.seasons active on active.is_active
  left join kut.player_season_state s on s.player_id=p.id and s.season_id=active.id
  where p.id=profile.player_id and p.is_active
) personal on true
where profile.id=auth.uid() and not profile.is_disabled

) gated
where kut.is_active_member();

revoke all on kut.my_club_value from public, anon;
grant select on kut.my_club_value to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- kut.club_value_leaderboard
-- Body verbatim from 20260917000000_duplicate_club_value.sql:101-134.
-- The `not p.is_disabled and p.role='user'` filter inside `totals` scopes the
-- leaderboard's SUBJECTS. The wrapper scopes its READER. Both are load-bearing;
-- neither subsumes the other.
-- ---------------------------------------------------------------------------
create or replace view kut.club_value_leaderboard
with (security_invoker = false, security_barrier = true)
as
select * from (

with resolved as (
  select c.owner_id,c.edition_id,e.player_id,
    round(10*power(1.08::numeric,(case when e.is_live then coalesce(s.live_ovr,30) else e.snapshot_ovr end)-30)
      * case when e.is_live then 1 else e.special_discard_multiplier end)::bigint as discard_value,
    count(*)::integer as copy_count
  from kut.user_cards c join kut.card_editions e on e.id=c.edition_id
  left join kut.seasons active on active.is_active
  left join kut.player_season_state s on s.player_id=e.player_id and s.season_id=active.id
  where c.burned_at is null group by c.owner_id,c.edition_id,e.player_id,e.is_live,e.snapshot_ovr,e.special_discard_multiplier,s.live_ovr
), owned as (
  select owner_id,sum(kut.duplicate_edition_contribution(discard_value,copy_count))::bigint as owned_cards_value,
    sum(copy_count)::integer as card_count,count(distinct player_id)::integer as unique_player_count
  from resolved group by owner_id
), totals as (
  select p.id,p.display_name,p.club_name,coalesce(w.balance,0)::bigint wallet_balance,
    coalesce(o.card_count,0)::integer card_count,coalesce(o.unique_player_count,0)::integer unique_player_count,
    coalesce(o.owned_cards_value,0)::bigint owned_cards_value,
    (coalesce(personal.base_value,0)*4)::bigint personal_card_bonus
  from kut.profiles p left join kut.wallets w on w.user_id=p.id left join owned o on o.owner_id=p.id
  left join lateral (
    select round(10*power(1.08::numeric,coalesce(s.live_ovr,30)-30))::bigint base_value
    from kut.players pl left join kut.seasons active on active.is_active
    left join kut.player_season_state s on s.player_id=pl.id and s.season_id=active.id
    where pl.id=p.player_id and pl.is_active
  ) personal on true where not p.is_disabled and p.role='user'
)
select rank() over(order by (wallet_balance+owned_cards_value+personal_card_bonus) desc,display_name)::integer rank,
  display_name,coalesce(nullif(btrim(club_name),''),display_name||'''s Club') club_name,
  (wallet_balance+owned_cards_value+personal_card_bonus)::bigint club_value,
  card_count,unique_player_count,id=auth.uid() is_current_user
from totals

) gated
where kut.is_active_member();

revoke all on kut.club_value_leaderboard from public, anon;
grant select on kut.club_value_leaderboard to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- kut.public_live_ratings
-- Body verbatim from 20260830000000_member_self_service_and_player_directory.sql:46-68.
-- `security_invoker = false` is now spelled out; it was previously the unstated
-- default. Zero references in src/ -- kept as a legacy projection, see ADR-079.
-- ---------------------------------------------------------------------------
create or replace view kut.public_live_ratings
with (security_invoker = false, security_barrier = true)
as
select * from (

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
  state.rarity_tier,
  p.photo_path
from kut.players p
join kut.player_season_state state on state.player_id = p.id
join kut.seasons season on season.id = state.season_id
where p.is_active
  and p.is_collectible
  and season.is_active

) gated
where kut.is_active_member();

revoke all on kut.public_live_ratings from public, anon;
grant select on kut.public_live_ratings to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- kut.chronicle_session_report_status
-- Body verbatim from 20260920090000_chronicle_database_deadline.sql:3-27.
-- ---------------------------------------------------------------------------
create or replace view kut.chronicle_session_report_status
with (security_invoker = false, security_barrier = true)
as
select * from (

select survey.session_id,
  survey.status as survey_status,
  survey.closes_at,
  count(attendance.player_id)::integer as attendee_count,
  count(report.player_id) filter(where report.status='submitted')::integer as submitted_reports,
  count(eligibility.user_id)::integer as eligible_accounts,
  coalesce(sum(
    case
      when survey.status='finalized' then result.effective_goals
      when override.session_id is not null then override.goals
      when report.status='submitted' then report.goals
      else null
    end
  ),0)::integer as goal_total,
  (survey.status='open' and survey.closes_at>now()) as accepting_reports
from kut.session_surveys survey
join kut.match_sessions session on session.id=survey.session_id and session.status='published'
left join kut.attendance attendance on attendance.session_id=survey.session_id
left join kut.session_survey_eligibility eligibility on eligibility.session_id=attendance.session_id and eligibility.player_id=attendance.player_id
left join kut.session_reports report on report.session_id=attendance.session_id and report.player_id=attendance.player_id
left join kut.session_goal_overrides override on override.session_id=attendance.session_id and override.player_id=attendance.player_id
left join kut.session_report_results result on result.session_id=attendance.session_id and result.player_id=attendance.player_id
group by survey.session_id,survey.status,survey.closes_at

) gated
where kut.is_active_member();

revoke all on kut.chronicle_session_report_status from public, anon;
grant select on kut.chronicle_session_report_status to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- kut.chronicle_session_reports
-- Body verbatim from 20260923000000_chronicle_results_visibility.sql:64-73.
-- The `survey.status='finalized'` join guard (ADR-066) is the only thing keeping
-- an open session out of this projection. It is inside the body. Do not drop it.
-- ---------------------------------------------------------------------------
create or replace view kut.chronicle_session_reports
with (security_invoker = false, security_barrier = true)
as
select * from (

select result.session_id,result.player_id,player.display_name,player.slug,result.effective_goals,
  result.goal_form,result.kudos_form,result.session_input,
  coalesce((select array_agg(category.title order by category.title) from kut.kudos_categories category where category.id=any(result.qualified_category_ids)),'{}') recognized_categories,
  (select count(*) from kut.session_reports report where report.session_id=result.session_id and report.status='submitted')::integer submitted_reports,
  (select count(*) from kut.session_survey_eligibility eligibility where eligibility.session_id=result.session_id and eligibility.user_id is not null)::integer eligible_accounts,
  (select count(*) from kut.attendance attendance where attendance.session_id=result.session_id)::integer attendee_count
from kut.session_report_results result join kut.players player on player.id=result.player_id
join kut.session_surveys survey on survey.session_id=result.session_id and survey.status='finalized'

) gated
where kut.is_active_member();

revoke all on kut.chronicle_session_reports from public, anon;
grant select on kut.chronicle_session_reports to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- kut.my_trade_offers
-- Body verbatim from 20260911000000_trade_offers.sql:1160-1209.
-- ---------------------------------------------------------------------------
create or replace view kut.my_trade_offers
with (security_invoker = false, security_barrier = true)
as
select * from (

select
  o.id as offer_id,
  o.listing_id,
  o.status,
  o.offered_coins,
  o.created_at,
  o.expires_at,
  o.resolved_at,
  o.coins_to_seller,
  o.coins_burned,
  o.proposer_id,
  o.seller_id,
  (o.proposer_id = auth.uid()) as is_outgoing,
  proposer.display_name as proposer_name,
  seller.display_name as seller_name,
  player.display_name as listing_card_name,
  player.slug as listing_card_slug,
  player.photo_path as listing_card_photo_path,
  listing.price as listing_price,
  listing.status as listing_status,
  coalesce(oc.card_count, 0)::integer as offered_card_count,
  coalesce(oc.cards, '[]'::jsonb) as offered_cards
from kut.trade_offers o
join kut.profiles proposer on proposer.id = o.proposer_id
join kut.profiles seller on seller.id = o.seller_id
join kut.market_listings listing on listing.id = o.listing_id
join kut.user_cards lcard on lcard.id = listing.card_id
join kut.card_editions ledition on ledition.id = lcard.edition_id
join kut.players player on player.id = ledition.player_id
left join lateral (
  select
    count(*) as card_count,
    jsonb_agg(jsonb_build_object(
      'card_id', tc.card_id,
      'display_name', p2.display_name,
      'ovr', coalesce(e2.snapshot_ovr, s2.live_ovr, 30),
      'rarity_tier', case when e2.is_live then coalesce(s2.rarity_tier, 'common') else 'common' end
    ) order by p2.display_name) as cards
  from kut.trade_offer_cards tc
  join kut.user_cards c2 on c2.id = tc.card_id
  join kut.card_editions e2 on e2.id = c2.edition_id
  join kut.players p2 on p2.id = e2.player_id
  left join kut.seasons as2 on as2.is_active
  left join kut.player_season_state s2 on s2.player_id = p2.id and s2.season_id = as2.id
  where tc.offer_id = o.id
) oc on true
where o.proposer_id = auth.uid() or o.seller_id = auth.uid()

) gated
where kut.is_active_member();

revoke all on kut.my_trade_offers from public, anon;
grant select on kut.my_trade_offers to authenticated, service_role;

