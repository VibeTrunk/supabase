-- Batch B (tester feedback #9), ADR-033: retire the untradeable concept.
--
-- Every Card Copy is now tradeable and discardable, starter cards included.
-- This removes kut.user_cards.is_tradeable and every guard/projection field
-- that referenced it. The starter grant, pack opening, discard, and market
-- list/buy operations no longer distinguish "locked" copies.
--
-- Tier: data-changing (ADR-032) -- drops a column and changes market/discard
-- RPC semantics. Take a fresh backup immediately before the hosted push.
--
-- Rollback DDL (restores the pre-ADR-033 shape; every surviving row was
-- is_tradeable = true, so the backfill is lossless):
--
--   alter table kut.user_cards
--     add column is_tradeable boolean not null default true;
--   -- then re-apply the function/view bodies from (latest wins):
--   --   20260830000000_member_self_service_and_player_directory.sql  (my_collection_cards)
--   --   20260816070000_wallet_starter_and_attendance_rewards.sql     (grant_starter_pack)
--   --   20260816070400_atomic_basic_pack_opening.sql                 (open_pack)
--   --   20260816070300_server_authoritative_card_discard.sql         (discard_card)
--   --   20260816070600_atomic_marketplace.sql                        (get_listing_bounds, create_listing)
--   --   20260817020100_include_buyer_in_sale_notifications.sql       (buy_listing)

-- 1. The private collection projection has a hard column dependency on
--    is_tradeable, so it must be dropped and rebuilt (create or replace view
--    cannot remove a column). Nothing in the schema selects from this view --
--    only the collection pages read it directly.
drop view kut.my_collection_cards;

-- 2. Drop the flag itself.
alter table kut.user_cards drop column is_tradeable;

-- 3. Rebuild the collection projection without is_tradeable (otherwise byte
--    for byte the 20260830000000 body).
create view kut.my_collection_cards
with (security_invoker = true, security_barrier = true)
as
select card.id as card_id, card.edition_id, card.source, card.acquired_at,
  edition.title as edition_title, edition.edition_type, edition.is_live,
  player.id as player_id, player.slug as player_slug, player.display_name, player.archetype,
  coalesce(edition.snapshot_ovr, state.live_ovr, 30) as ovr,
  coalesce(edition.snapshot_pac, state.pac, 30) as pac, coalesce(edition.snapshot_sho, state.sho, 30) as sho,
  coalesce(edition.snapshot_pas, state.pas, 30) as pas, coalesce(edition.snapshot_dri, state.dri, 30) as dri,
  coalesce(edition.snapshot_def, state.def, 30) as def, coalesce(edition.snapshot_phy, state.phy, 30) as phy,
  case when edition.is_live then coalesce(state.rarity_tier, 'common') when coalesce(edition.snapshot_ovr, 30) >= 70 then 'elite' when coalesce(edition.snapshot_ovr, 30) >= 60 then 'holo' when coalesce(edition.snapshot_ovr, 30) >= 50 then 'gold' when coalesce(edition.snapshot_ovr, 30) >= 40 then 'silver' when coalesce(edition.snapshot_ovr, 30) >= 30 then 'bronze' else 'common' end as rarity_tier,
  round(10 * power(1.08::numeric, coalesce(edition.snapshot_ovr, state.live_ovr, 30) - 30) * case when edition.is_live then 1 else coalesce(edition.special_discard_multiplier, 1) end)::bigint as discard_value,
  listing.id as active_listing_id, listing.price as active_listing_price, listing.expires_at as active_listing_expires_at,
  player.photo_path
from kut.user_cards card
join kut.card_editions edition on edition.id = card.edition_id
join kut.players player on player.id = edition.player_id
left join kut.seasons active_season on active_season.is_active
left join kut.player_season_state state on state.player_id = player.id and state.season_id = active_season.id
left join kut.market_listings listing on listing.card_id = card.id and listing.status = 'active' and listing.expires_at > now()
where card.owner_id = auth.uid() and card.burned_at is null;

revoke all on kut.my_collection_cards from public;
grant select on kut.my_collection_cards to authenticated, service_role;

-- 4. Starter grant: mint plain copies.
create or replace function kut.grant_starter_pack(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
declare
  v_edition_ids uuid[];
begin
  perform 1 from kut.profiles where id = p_user_id and not is_disabled for update;
  if not found then
    raise exception 'active profile not found' using errcode = 'P0002';
  end if;

  if exists (select 1 from kut.profiles where id = p_user_id and starter_claimed_at is not null) then
    raise exception 'starter pack already claimed' using errcode = 'P0001';
  end if;

  select array_agg(id) into v_edition_ids
  from (
    select edition.id
    from kut.card_editions edition
    join kut.players player on player.id = edition.player_id
    where edition.is_live and player.is_active and player.is_collectible
    order by random()
    limit 3
  ) eligible;

  if coalesce(array_length(v_edition_ids, 1), 0) <> 3 then
    raise exception 'at least three eligible Live editions are required' using errcode = 'P0002';
  end if;

  update kut.profiles set starter_claimed_at = now() where id = p_user_id;
  insert into kut.wallets (user_id, balance) values (p_user_id, 0)
  on conflict (user_id) do nothing;
  update kut.wallets set balance = balance + 250, updated_at = now() where user_id = p_user_id;
  insert into kut.wallet_ledger (user_id, amount, reason, reference_type, reference_id, idempotency_key)
  values (p_user_id, 250, 'starter', 'profile', p_user_id, 'starter:' || p_user_id::text);
  insert into kut.user_cards (edition_id, owner_id, source)
  select edition_id, p_user_id, 'starter'
  from unnest(v_edition_ids) as edition_id;

  return jsonb_build_object('coins', 250, 'edition_ids', to_jsonb(v_edition_ids));
end;
$$;

-- 5. Pack opening: mint plain copies.
create or replace function kut.open_pack(
  p_pack_slug text,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
declare
  v_user_id uuid := auth.uid();
  v_pack record;
  v_opening_id uuid;
  v_balance bigint;
  v_slot integer;
  v_edition_id uuid;
  v_card_id uuid;
  v_ledger_key text := 'pack:' || p_idempotency_key::text;
begin
  if v_user_id is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  if p_idempotency_key is null or p_pack_slug !~ '^[a-z0-9]+(?:-[a-z0-9]+)*$' then
    raise exception 'valid pack and idempotency key are required' using errcode = '22023';
  end if;

  perform 1 from kut.profiles where id = v_user_id and not is_disabled for update;
  if not found then
    raise exception 'active profile not found' using errcode = '42501';
  end if;

  select id into v_opening_id
  from kut.pack_openings
  where user_id = v_user_id
    and idempotency_key = p_idempotency_key;

  if found then
    return jsonb_build_object('opening_id', v_opening_id, 'already_processed', true);
  end if;

  select id, title, price, cards_per_pack
  into v_pack
  from kut.pack_definitions
  where slug = p_pack_slug
    and is_active;

  if not found then
    raise exception 'active pack not found' using errcode = 'P0002';
  end if;

  insert into kut.wallets (user_id, balance)
  values (v_user_id, 0)
  on conflict (user_id) do nothing;

  select balance into v_balance
  from kut.wallets
  where user_id = v_user_id
  for update;

  -- A second same-key call can have waited for the wallet lock.
  select id into v_opening_id
  from kut.pack_openings
  where user_id = v_user_id
    and idempotency_key = p_idempotency_key;

  if found then
    return jsonb_build_object('opening_id', v_opening_id, 'already_processed', true);
  end if;

  if v_balance < v_pack.price then
    raise exception 'insufficient TF Coins for this pack' using errcode = 'P0001';
  end if;

  insert into kut.pack_openings (user_id, pack_id, price_paid, idempotency_key)
  values (v_user_id, v_pack.id, v_pack.price, p_idempotency_key)
  returning id into v_opening_id;

  update kut.wallets
  set balance = balance - v_pack.price,
      updated_at = now()
  where user_id = v_user_id;

  insert into kut.wallet_ledger (
    user_id, amount, reason, reference_type, reference_id, idempotency_key
  ) values (
    v_user_id, -v_pack.price, 'pack_purchase', 'pack_opening', v_opening_id, v_ledger_key
  );

  for v_slot in 1..v_pack.cards_per_pack loop
    select candidate.id
    into v_edition_id
    from (
      select
        edition.id,
        case coalesce(state.rarity_tier, 'common')
          when 'common' then 100
          when 'bronze' then 60
          when 'silver' then 30
          when 'gold' then 12
          when 'holo' then 4
          when 'elite' then 1
        end as weight
      from kut.card_editions edition
      join kut.players player on player.id = edition.player_id
      left join kut.seasons active_season on active_season.is_active
      left join kut.player_season_state state
        on state.player_id = player.id
        and state.season_id = active_season.id
      where edition.is_live
        and player.is_active
        and player.is_collectible
    ) candidate
    order by -ln(greatest(random(), 0.0000001)) / candidate.weight
    limit 1;

    if v_edition_id is null then
      raise exception 'no eligible Live editions are available' using errcode = 'P0002';
    end if;

    insert into kut.user_cards (edition_id, owner_id, source)
    values (v_edition_id, v_user_id, 'pack')
    returning id into v_card_id;

    insert into kut.pack_opening_cards (opening_id, slot, card_id)
    values (v_opening_id, v_slot, v_card_id);

    update kut.card_editions
    set minted_count = minted_count + 1
    where id = v_edition_id;
  end loop;

  return jsonb_build_object('opening_id', v_opening_id, 'already_processed', false);
end;
$$;

-- 6. Discard: no tradeability gate. An active market listing still blocks a
--    burn via the user_cards_prevent_burning_listed_card trigger.
create or replace function kut.discard_card(
  p_card_id uuid,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
declare
  v_user_id uuid := auth.uid();
  v_card record;
  v_existing record;
  v_amount bigint;
  v_ledger_key text := 'discard:' || p_idempotency_key::text;
begin
  if v_user_id is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  if p_idempotency_key is null then
    raise exception 'idempotency key is required' using errcode = '22023';
  end if;

  perform 1
  from kut.profiles
  where id = v_user_id
    and not is_disabled;

  if not found then
    raise exception 'active profile not found' using errcode = '42501';
  end if;

  select amount, reference_id
  into v_existing
  from kut.wallet_ledger
  where user_id = v_user_id
    and idempotency_key = v_ledger_key
    and reason = 'discard';

  if found then
    if v_existing.reference_id is distinct from p_card_id then
      raise exception 'idempotency key was already used for another card' using errcode = '22023';
    end if;

    return jsonb_build_object('card_id', p_card_id, 'coins', v_existing.amount, 'already_processed', true);
  end if;

  select
    card.id,
    edition.is_live,
    coalesce(edition.snapshot_ovr, state.live_ovr) as ovr,
    coalesce(edition.special_discard_multiplier, 1) as special_discard_multiplier
  into v_card
  from kut.user_cards card
  join kut.card_editions edition on edition.id = card.edition_id
  left join kut.seasons active_season on active_season.is_active
  left join kut.player_season_state state
    on state.player_id = edition.player_id
    and state.season_id = active_season.id
  where card.id = p_card_id
    and card.owner_id = v_user_id
    and card.burned_at is null
  for update of card;

  if not found then
    -- A matching retry can arrive after another request committed the burn.
    select amount, reference_id
    into v_existing
    from kut.wallet_ledger
    where user_id = v_user_id
      and idempotency_key = v_ledger_key
      and reason = 'discard';

    if found and v_existing.reference_id = p_card_id then
      return jsonb_build_object('card_id', p_card_id, 'coins', v_existing.amount, 'already_processed', true);
    end if;

    raise exception 'card not found or no longer active' using errcode = 'P0002';
  end if;

  if v_card.ovr is null then
    raise exception 'card rating is unavailable' using errcode = 'P0002';
  end if;

  v_amount := round(
    10 * power(1.08::numeric, v_card.ovr - 30)
    * case when v_card.is_live then 1 else v_card.special_discard_multiplier end
  )::bigint;

  update kut.user_cards
  set burned_at = now()
  where id = v_card.id
    and burned_at is null;

  insert into kut.wallets (user_id, balance)
  values (v_user_id, 0)
  on conflict (user_id) do nothing;

  insert into kut.wallet_ledger (
    user_id,
    amount,
    reason,
    reference_type,
    reference_id,
    idempotency_key
  )
  values (
    v_user_id,
    v_amount,
    'discard',
    'user_card',
    v_card.id,
    v_ledger_key
  );

  update kut.wallets
  set balance = balance + v_amount,
      updated_at = now()
  where user_id = v_user_id;

  return jsonb_build_object('card_id', v_card.id, 'coins', v_amount, 'already_processed', false);
end;
$$;

-- 7. Listing bounds: any owned, unburned copy qualifies.
create or replace function kut.get_listing_bounds(p_card_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
declare
  v_user_id uuid := auth.uid();
  v_edition_id uuid;
  v_discard bigint;
  v_reference bigint;
begin
  if v_user_id is null then raise exception 'authentication required' using errcode = '42501'; end if;
  select edition_id into v_edition_id from kut.user_cards
  where id = p_card_id and owner_id = v_user_id and burned_at is null;
  if not found then raise exception 'eligible owned card not found' using errcode = 'P0002'; end if;

  v_discard := kut.card_discard_value(p_card_id);
  v_reference := kut.market_reference_value(v_edition_id, v_discard);
  return jsonb_build_object(
    'discard_value', v_discard,
    'reference_value', v_reference,
    'minimum_price', greatest(1, floor(v_discard * 0.80)::bigint),
    'maximum_price', greatest(100, ceil(v_reference * 5)::bigint)
  );
end;
$$;

-- 8. Create listing: no tradeability gate.
create or replace function kut.create_listing(p_card_id uuid, p_price bigint)
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
begin
  if v_user_id is null then raise exception 'authentication required' using errcode = '42501'; end if;
  if p_price is null or p_price < 1 then raise exception 'listing price must be positive' using errcode = '22023'; end if;
  perform 1 from kut.profiles where id = v_user_id and not is_disabled for update;
  if not found then raise exception 'active profile not found' using errcode = '42501'; end if;

  select id into v_card from kut.user_cards
  where id = p_card_id and owner_id = v_user_id and burned_at is null for update;
  if not found then raise exception 'card is not eligible for listing' using errcode = 'P0001'; end if;
  update kut.market_listings set status = 'expired'
  where card_id = p_card_id and status = 'active' and expires_at <= now();
  if exists (select 1 from kut.market_listings where card_id = p_card_id and status = 'active') then
    raise exception 'card already has an active listing' using errcode = 'P0001';
  end if;

  v_bounds := kut.get_listing_bounds(p_card_id);
  if p_price < (v_bounds ->> 'minimum_price')::bigint or p_price > (v_bounds ->> 'maximum_price')::bigint then
    raise exception 'listing price is outside the current allowed range' using errcode = '22023';
  end if;

  insert into kut.market_listings(card_id, seller_id, price)
  values (p_card_id, v_user_id, p_price)
  returning id into v_listing_id;
  return jsonb_build_object('listing_id', v_listing_id, 'expires_at', now() + interval '24 hours');
end;
$$;

-- 9. Buy listing: no tradeability gate on the seller-ownership recheck.
--    Otherwise byte for byte the 20260817020100 body (the "TF Coins" strings
--    there are Batch C's concern, not this migration's).
create or replace function kut.buy_listing(p_listing_id uuid, p_idempotency_key uuid)
returns jsonb
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
declare
  v_buyer_id uuid := auth.uid(); v_listing record; v_sale record; v_wallet record;
  v_buyer_balance bigint; v_tax bigint; v_receipt bigint; v_sale_id uuid;
  v_player_name text; v_buyer_name text;
begin
  if v_buyer_id is null then raise exception 'authentication required' using errcode = '42501'; end if;
  if p_idempotency_key is null then raise exception 'idempotency key is required' using errcode = '22023'; end if;
  select display_name into v_buyer_name from kut.profiles where id = v_buyer_id and not is_disabled for update;
  if not found then raise exception 'active profile not found' using errcode = '42501'; end if;
  select id, listing_id, sale_price into v_sale from kut.market_sales where buyer_id = v_buyer_id and buyer_idempotency_key = p_idempotency_key;
  if found then
    if v_sale.listing_id <> p_listing_id then raise exception 'idempotency key was already used for another listing' using errcode = '22023'; end if;
    return jsonb_build_object('sale_id', v_sale.id, 'price', v_sale.sale_price, 'already_processed', true);
  end if;
  select id, card_id, seller_id, price, status, expires_at into v_listing from kut.market_listings where id = p_listing_id for update;
  if not found then raise exception 'listing not found' using errcode = 'P0002'; end if;
  if v_listing.status <> 'active' or v_listing.expires_at <= now() then
    if v_listing.status = 'active' then update kut.market_listings set status = 'expired' where id = v_listing.id; end if;
    raise exception 'listing is no longer active' using errcode = 'P0001';
  end if;
  if v_listing.seller_id = v_buyer_id then raise exception 'you cannot buy your own listing' using errcode = 'P0001'; end if;
  insert into kut.wallets(user_id, balance) values (v_buyer_id, 0), (v_listing.seller_id, 0) on conflict (user_id) do nothing;
  -- Consistent UUID order prevents deadlocks when users buy one another's cards concurrently.
  for v_wallet in select user_id, balance from kut.wallets where user_id in (v_buyer_id, v_listing.seller_id) order by user_id for update loop
    if v_wallet.user_id = v_buyer_id then v_buyer_balance := v_wallet.balance; end if;
  end loop;
  select balance into v_buyer_balance from kut.wallets where user_id = v_buyer_id;
  if v_buyer_balance < v_listing.price then raise exception 'insufficient TF Coins for this listing' using errcode = 'P0001'; end if;
  select player.display_name into v_player_name
  from kut.user_cards card
  join kut.card_editions edition on edition.id = card.edition_id
  join kut.players player on player.id = edition.player_id
  where card.id = v_listing.card_id and card.owner_id = v_listing.seller_id and card.burned_at is null
  for update of card;
  if not found then raise exception 'seller no longer owns an eligible card' using errcode = 'P0002'; end if;
  v_tax := greatest(1, ceil(v_listing.price * 0.05)::bigint); v_receipt := v_listing.price - v_tax;
  insert into kut.market_sales(listing_id, card_id, edition_id, seller_id, buyer_id, sale_price, tax_amount, seller_receipt, buyer_idempotency_key)
  select v_listing.id, card.id, card.edition_id, v_listing.seller_id, v_buyer_id, v_listing.price, v_tax, v_receipt, p_idempotency_key from kut.user_cards card where card.id = v_listing.card_id
  returning id into v_sale_id;
  update kut.wallets set balance = balance - v_listing.price, updated_at = now() where user_id = v_buyer_id;
  update kut.wallets set balance = balance + v_receipt, updated_at = now() where user_id = v_listing.seller_id;
  insert into kut.wallet_ledger(user_id, amount, reason, reference_type, reference_id, idempotency_key) values
    (v_buyer_id, -v_receipt, 'market_buy', 'market_sale', v_sale_id, 'market-buy:' || p_idempotency_key::text),
    (v_buyer_id, -v_tax, 'market_tax', 'market_sale', v_sale_id, 'market-tax:' || p_idempotency_key::text),
    (v_listing.seller_id, v_receipt, 'market_sale', 'market_sale', v_sale_id, 'market-sale:' || v_sale_id::text);
  update kut.user_cards set owner_id = v_buyer_id where id = v_listing.card_id;
  update kut.market_listings set status = 'sold', sold_at = now(), buyer_id = v_buyer_id where id = v_listing.id;
  insert into kut.user_notifications(user_id, event_type, title, body, reference_type, reference_id) values
    (v_buyer_id, 'market_purchase', 'Card bought', format('You bought %s for %s TF Coins.', v_player_name, v_listing.price), 'market_sale', v_sale_id),
    (v_listing.seller_id, 'market_sale', 'Card sold', format('Your %s card sold to %s for %s TF Coins. You received %s TF Coins after tax.', v_player_name, v_buyer_name, v_listing.price, v_receipt), 'market_sale', v_sale_id);
  return jsonb_build_object('sale_id', v_sale_id, 'price', v_listing.price, 'tax', v_tax, 'already_processed', false);
end;
$$;
