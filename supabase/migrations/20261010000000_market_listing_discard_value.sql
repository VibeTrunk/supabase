-- ADR-103 / KB-027 -- the market shows what a listed card discards for, as the
-- floor to judge its asking price against.
--
-- Tier: additive, projection-only, plus one function grant. kut.active_market_
-- listings gains one trailing column, `discard_value`, read from the existing
-- kut.card_discard_value(card.id) -- the same function kut.get_listing_bounds
-- and kut.discard_card use. The formula is deliberately NOT inlined a third
-- time (KB-025 already has the card page and the listing bounds reading it from
-- two places). No table is created, altered or written; no DML. Rides the
-- scheduled backup.
--
-- Shape: the view body is copied verbatim from its latest version,
-- 20261002000000_cast_on_market_and_packs.sql. The only changes are a comma
-- after `edition.is_live` and the appended select-list item. `create or
-- replace view` can only append columns, and appending last keeps every
-- existing column's name, order and type (the ADR-073 lesson).
-- kut.my_wanted_cards reads this view, which is why this is `create or
-- replace`, never `drop view`.
--
-- Two things the function needs, both verified on the local stack:
--   * A function called inside a view is checked against the CALLER, not the
--     view owner, even in a definer view. card_discard_value has been revoked
--     from `authenticated` since 20260816070600 and was never granted to
--     `service_role`, so without the grant below every read of this view (and
--     of kut.my_wanted_cards, which reads it) by either role fails with
--     "permission denied for function card_discard_value" -- even with zero
--     rows. That is why every older view inlined the formula. The grant
--     matches the view's own SELECT grant: authenticated and service_role.
--   * card_discard_value raises P0002 when the card has no rating (no snapshot
--     and no live state in the active season), where this view falls back to
--     OVR 30. One such listing would break the whole market read, so the call
--     is guarded and such a row gets a null discard_value. The guard repeats
--     the function's own rating lookup, not the formula.
--
-- Access is unchanged on the view: it stays a definer view (security_invoker =
-- false, security_barrier = true) gated on kut.is_active_member() (ADR-079),
-- with the same grants. The new column sits inside the gated body, so the
-- `select *` wrapper exposes it and a denied caller still reads zero rows.
-- Never flip it to security_invoker (KB-013).
--
-- The function grant is an access change, and a small one: any `authenticated`
-- JWT can now call kut.card_discard_value(uuid) directly and learn a card's
-- discard value, given its id. The value is derivable from public ratings, and
-- card ids are only readable through member-gated views. service_role already
-- bypasses RLS, so it gains nothing it could not read. anon still cannot call
-- it.
--
-- Deploy ordering: Vercel deploys on merge, before the hosted push. The market
-- pages read this view with `select("*")` and render nothing when the column is
-- absent or null, so the listing page simply has no discard line until this
-- lands.
--
-- Rollback (optional -- the extra column is harmless to every reader):
--   `create or replace` cannot drop columns, so the view is dropped and re-run.
--   1. drop view kut.my_wanted_cards;
--      drop view kut.active_market_listings;
--      Re-run the kut.active_market_listings block of
--      20261002000000_cast_on_market_and_packs.sql (with its revoke/grant),
--      then the whole of 20260920060000_wanted_market_listing_visibility.sql.
--   2. revoke execute on function kut.card_discard_value(uuid) from authenticated, service_role;

-- ---------------------------------------------------------------------------
-- kut.active_market_listings
-- Body verbatim from 20261002000000_cast_on_market_and_packs.sql, plus
-- `discard_value` appended last.
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
  listing.seller_id,
  edition.player_id,
  edition.is_live,
  case
    when coalesce(edition.snapshot_ovr, state.live_ovr) is not null
      then kut.card_discard_value(card.id)
  end as discard_value
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

-- Every role granted SELECT on the view reads it as itself, so it must be able
-- to execute the function it calls. anon stays revoked (20260816070600).
grant execute on function kut.card_discard_value(uuid) to authenticated, service_role;
