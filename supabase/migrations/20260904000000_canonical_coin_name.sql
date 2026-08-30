-- Batch C (tester feedback #7), ADR-034: "KUT Coins" is the one currency name.
--
-- The visible front-end is already all "KUT Coins" (Batch A + the 2026-08-17
-- sweep). Three server-side surfaces still said "TF Coins":
--   * kut.user_notifications.body for market_purchase / market_sale rows
--     ("You bought X for N TF Coins." / "... sold to ... for N TF Coins. You
--     received N TF Coins after tax."), rendered verbatim on /messages -- from
--     both the live buy_listing body and rows already on hosted;
--   * the insufficient-funds raise strings in open_pack and buy_listing (not
--     user-visible today -- actions.ts catches and rewrites them -- but wrong).
--
-- Nothing internal changes: wallet_ledger.reason values, column names, prices,
-- formulas, and the economy invariants (Part L) are all untouched. This is a
-- pure display-string sweep.
--
-- Tier: data-changing (ADR-032) -- one backfill UPDATE on kut.user_notifications.
-- Take a fresh backup immediately before the hosted push. The migration is
-- trivially SQL-reversible (see below).
--
-- Rollback DDL:
--
--   update kut.user_notifications
--   set body = replace(body, 'KUT Coins', 'TF Coins')
--   where event_type in ('market_purchase', 'market_sale')
--     and body like '%KUT Coins%';
--   -- then re-apply the open_pack / buy_listing bodies from
--   --   20260903000000_drop_is_tradeable.sql  (the 'TF Coins' variants)
--
-- The reverse UPDATE is lossless: only market_purchase / market_sale bodies
-- ever carried "TF Coins", and this migration is the only thing that puts
-- "KUT Coins" into them (attendance_reward bodies already said "KUT Coins"
-- since ADR-028 and are left out of both directions by the event_type filter).

-- 1. Pack opening: "TF Coins" -> "KUT Coins" in the insufficient-funds raise.
--    Otherwise byte for byte the 20260903000000 body.
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
    raise exception 'insufficient KUT Coins for this pack' using errcode = 'P0001';
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

-- 2. Buy listing: "TF Coins" -> "KUT Coins" in the insufficient-funds raise and
--    in both market_purchase / market_sale notification bodies. Otherwise byte
--    for byte the 20260903000000 body.
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
  if v_buyer_balance < v_listing.price then raise exception 'insufficient KUT Coins for this listing' using errcode = 'P0001'; end if;
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
    (v_buyer_id, 'market_purchase', 'Card bought', format('You bought %s for %s KUT Coins.', v_player_name, v_listing.price), 'market_sale', v_sale_id),
    (v_listing.seller_id, 'market_sale', 'Card sold', format('Your %s card sold to %s for %s KUT Coins. You received %s KUT Coins after tax.', v_player_name, v_buyer_name, v_listing.price, v_receipt), 'market_sale', v_sale_id);
  return jsonb_build_object('sale_id', v_sale_id, 'price', v_listing.price, 'tax', v_tax, 'already_processed', false);
end;
$$;

-- 3. Backfill existing inbox rows. Only market_purchase / market_sale bodies
--    ever contained "TF Coins"; 20260817020000 / ...020100 each backfilled
--    these once with the old wording, so the rows exist on hosted.
update kut.user_notifications
set body = replace(body, 'TF Coins', 'KUT Coins')
where event_type in ('market_purchase', 'market_sale')
  and body like '%TF Coins%';
