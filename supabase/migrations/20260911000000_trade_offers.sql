-- Trade offers on transfer-market listings, with coin + card escrow.
-- See ADR-042. Promotes the Phase-4 "trading offers" idea (BUILD_SPEC Part
-- XXXIV) to a shipped feature.
--
-- A member browsing the market can offer KUT Coins and/or up to 3 of their own
-- cards for a listing instead of paying the buy-now price. The offered coins
-- AND cards are escrowed the moment the offer is made:
--
--   * coins leave the proposer's wallet immediately (wallet_ledger reason
--     'trade_escrow') and are refunded ('trade_unescrow') on
--     reject / withdraw / expiry, or paid to the seller ('trade_sale', minus a
--     5% burn) on accept;
--   * each offered card gets user_cards.held_by_offer_id set, which blocks
--     listing / discarding / burning it until the offer resolves.
--
-- Offers expire 12h after they are made (kut.expire_trade_offers, called
-- lazily on the market pages and by the Vercel cron). Accepting an offer runs
-- the same atomic ownership+wallet swap as kut.buy_listing, marks the listing
-- sold, and auto-rejects+refunds every other active offer on that listing.
-- Cancelling or buying out a listing does the same to its pending offers.
--
-- Accepted trades are deliberately NOT written to kut.market_sales, so they do
-- not count as qualifying sales for kut.market_reference_value (an offer is a
-- private negotiation, not a price signal). They surface in kut.activity_feed
-- as a 'trade' row.
--
-- Tier: data-changing (ADR-032) -- new escrow economy, new wallet_ledger
-- reasons, guards added to create_listing / discard_card / cancel_listing /
-- buy_listing. Fresh backup immediately before the hosted push.
--
-- Rollback DDL:
--   drop view kut.my_trade_offers;
--   -- restore kut.activity_feed to its 20260908000000 body;
--   -- restore kut.my_collection_cards to its 20260903000000 body;
--   -- restore kut.create_listing / kut.discard_card / kut.cancel_listing /
--   --   kut.buy_listing to their pre-ADR-042 bodies;
--   drop function kut.propose_trade(uuid, bigint, uuid[], uuid);
--   drop function kut.respond_to_trade(uuid, boolean, uuid);
--   drop function kut.withdraw_trade(uuid);
--   drop function kut.expire_trade_offers();
--   drop function kut._refund_trade_offer(uuid);
--   alter table kut.user_cards drop column held_by_offer_id;
--   drop table kut.trade_offer_cards;
--   drop table kut.trade_offers;
--   alter table kut.wallet_ledger drop constraint wallet_ledger_reason_check;
--   alter table kut.wallet_ledger add constraint wallet_ledger_reason_check
--     check (reason in ('starter','attendance_reward','pack_purchase','discard',
--       'market_sale','market_buy','market_tax','admin_correction','admin_grant',
--       'admin_reset','bibs_bonus'));
--   alter table kut.user_notifications drop constraint user_notifications_event_type_check;
--   alter table kut.user_notifications add constraint user_notifications_event_type_check
--     check (event_type in ('market_sale','market_purchase','attendance_reward',
--       'pack_opened','admin_notice','bibs_bonus'));

-- 1. Tables -----------------------------------------------------------------
create table kut.trade_offers (
  id uuid primary key default gen_random_uuid(),
  listing_id uuid not null references kut.market_listings(id) on delete restrict,
  proposer_id uuid not null references kut.profiles(id) on delete restrict,
  seller_id uuid not null references kut.profiles(id) on delete restrict,
  offered_coins bigint not null default 0 check (offered_coins >= 0),
  status text not null default 'active'
    check (status in ('active', 'accepted', 'rejected', 'withdrawn', 'expired')),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '12 hours'),
  resolved_at timestamptz,
  proposer_idempotency_key uuid not null,
  responder_idempotency_key uuid,
  coins_to_seller bigint,
  coins_burned bigint,
  settled_card_id uuid references kut.user_cards(id) on delete set null,
  check (proposer_id <> seller_id),
  check ((status = 'active') = (resolved_at is null)),
  unique (proposer_id, proposer_idempotency_key)
);

-- At most one live offer per (listing, proposer).
create unique index trade_offers_one_active_per_pair
  on kut.trade_offers (listing_id, proposer_id) where status = 'active';
create index trade_offers_seller_inbox on kut.trade_offers (seller_id, status, created_at desc);
create index trade_offers_proposer_outbox on kut.trade_offers (proposer_id, status, created_at desc);
create index trade_offers_expiry on kut.trade_offers (status, expires_at);
create index trade_offers_listing on kut.trade_offers (listing_id, status);

create table kut.trade_offer_cards (
  offer_id uuid not null references kut.trade_offers(id) on delete cascade,
  card_id uuid not null references kut.user_cards(id) on delete restrict,
  primary key (offer_id, card_id)
);
create index trade_offer_cards_card on kut.trade_offer_cards (card_id);

-- 2. Card escrow lock -----------------------------------------------------
alter table kut.user_cards
  add column held_by_offer_id uuid references kut.trade_offers(id) on delete set null;
create index user_cards_held_by_offer_idx on kut.user_cards (held_by_offer_id)
  where held_by_offer_id is not null;

-- 3. Widen wallet_ledger.reason -----------------------------------------------
do $$
declare
  v_name text;
begin
  select conname into v_name
  from pg_constraint
  where conrelid = 'kut.wallet_ledger'::regclass
    and contype = 'c'
    and pg_get_constraintdef(oid) ilike '%market_tax%'
    and pg_get_constraintdef(oid) ilike '%reason%';
  if v_name is null then
    raise exception 'could not locate the wallet_ledger.reason check constraint';
  end if;
  execute format('alter table kut.wallet_ledger drop constraint %I', v_name);
end $$;

alter table kut.wallet_ledger
  add constraint wallet_ledger_reason_check
  check (reason in (
    'starter', 'attendance_reward', 'pack_purchase', 'discard',
    'market_sale', 'market_buy', 'market_tax', 'admin_correction',
    'admin_grant', 'admin_reset', 'bibs_bonus',
    'trade_escrow', 'trade_unescrow', 'trade_sale'
  ));

-- 4. Widen user_notifications.event_type ------------------------------------
do $$
declare
  v_name text;
begin
  select conname into v_name
  from pg_constraint
  where conrelid = 'kut.user_notifications'::regclass
    and contype = 'c'
    and pg_get_constraintdef(oid) ilike '%event_type%'
    and pg_get_constraintdef(oid) ilike '%market_sale%';
  if v_name is null then
    raise exception 'could not locate the user_notifications.event_type check constraint';
  end if;
  execute format('alter table kut.user_notifications drop constraint %I', v_name);
end $$;

alter table kut.user_notifications
  add constraint user_notifications_event_type_check
  check (event_type in (
    'market_sale', 'market_purchase', 'attendance_reward', 'pack_opened',
    'admin_notice', 'bibs_bonus', 'trade_offer', 'trade_response'
  ));

-- 5. RLS ------------------------------------------------------------------
alter table kut.trade_offers enable row level security;
alter table kut.trade_offer_cards enable row level security;

create policy "members read their own trade offers" on kut.trade_offers
  for select to authenticated
  using (proposer_id = auth.uid() or seller_id = auth.uid() or kut.is_admin());

create policy "members read cards in their own trade offers" on kut.trade_offer_cards
  for select to authenticated
  using (exists (
    select 1 from kut.trade_offers o
    where o.id = trade_offer_cards.offer_id
      and (o.proposer_id = auth.uid() or o.seller_id = auth.uid() or kut.is_admin())
  ));

grant select on kut.trade_offers, kut.trade_offer_cards to authenticated, service_role;

-- 6. Escrow-refund helper --------------------------------------------------
-- Releases every card hold for an offer and refunds its escrowed coins once
-- (guarded by the ledger idempotency key). Does NOT change offer.status --
-- each caller sets the terminal status and sends its own notification.
create or replace function kut._refund_trade_offer(p_offer_id uuid)
returns void
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
declare
  v_offer record;
begin
  select id, proposer_id, offered_coins
  into v_offer
  from kut.trade_offers
  where id = p_offer_id
  for update;
  if not found then
    return;
  end if;

  update kut.user_cards set held_by_offer_id = null where held_by_offer_id = p_offer_id;

  if v_offer.offered_coins > 0
     and not exists (
       select 1 from kut.wallet_ledger
       where idempotency_key = 'trade-unescrow:' || p_offer_id::text
     ) then
    insert into kut.wallets(user_id, balance) values (v_offer.proposer_id, 0)
      on conflict (user_id) do nothing;
    update kut.wallets
      set balance = balance + v_offer.offered_coins, updated_at = now()
      where user_id = v_offer.proposer_id;
    insert into kut.wallet_ledger(user_id, amount, reason, reference_type, reference_id, idempotency_key)
    values (v_offer.proposer_id, v_offer.offered_coins, 'trade_unescrow', 'trade_offer', p_offer_id,
      'trade-unescrow:' || p_offer_id::text);
  end if;
end;
$$;

revoke execute on function kut._refund_trade_offer(uuid) from public, anon, authenticated;

-- 7. propose_trade -------------------------------------------------------
create or replace function kut.propose_trade(
  p_listing_id uuid,
  p_offered_coins bigint,
  p_offered_card_ids uuid[],
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
declare
  v_user_id uuid := auth.uid();
  v_display_name text;
  v_existing record;
  v_offered_coins bigint := coalesce(p_offered_coins, 0);
  v_card_ids uuid[];
  v_card_count integer;
  v_listing record;
  v_edition_id uuid;
  v_discard bigint;
  v_reference bigint;
  v_max_coins bigint;
  v_balance bigint;
  v_offer_id uuid;
  v_seller_name text;
  v_player_name text;
begin
  if v_user_id is null then raise exception 'authentication required' using errcode = '42501'; end if;
  if p_idempotency_key is null then raise exception 'idempotency key is required' using errcode = '22023'; end if;

  select id, listing_id, status into v_existing
  from kut.trade_offers
  where proposer_id = v_user_id and proposer_idempotency_key = p_idempotency_key;
  if found then
    if v_existing.listing_id <> p_listing_id then
      raise exception 'idempotency key was already used for another listing' using errcode = '22023';
    end if;
    return jsonb_build_object('offer_id', v_existing.id, 'status', v_existing.status, 'already_processed', true);
  end if;

  select display_name into v_display_name from kut.profiles where id = v_user_id and not is_disabled for update;
  if not found then raise exception 'active profile not found' using errcode = '42501'; end if;

  if v_offered_coins < 0 then raise exception 'offered coins cannot be negative' using errcode = '22023'; end if;

  select coalesce(array_agg(distinct cid), '{}')
  into v_card_ids
  from unnest(coalesce(p_offered_card_ids, '{}'::uuid[])) as cid
  where cid is not null;
  v_card_count := coalesce(array_length(v_card_ids, 1), 0);

  if v_offered_coins = 0 and v_card_count = 0 then
    raise exception 'an offer must include coins or at least one card' using errcode = 'P0001';
  end if;
  if v_card_count > 3 then
    raise exception 'an offer can include at most 3 cards' using errcode = 'P0001';
  end if;
  if (select count(*) from kut.trade_offers where proposer_id = v_user_id and status = 'active') >= 10 then
    raise exception 'you already have the maximum of 10 active trade offers' using errcode = 'P0001';
  end if;

  select l.id, l.card_id, l.seller_id, l.status, l.expires_at
  into v_listing
  from kut.market_listings l
  where l.id = p_listing_id
  for update;
  if not found then raise exception 'listing not found' using errcode = 'P0002'; end if;
  if v_listing.status <> 'active' or v_listing.expires_at <= now() then
    raise exception 'listing is no longer active' using errcode = 'P0001';
  end if;
  if v_listing.seller_id = v_user_id then
    raise exception 'you cannot make an offer on your own listing' using errcode = 'P0001';
  end if;
  if exists (
    select 1 from kut.trade_offers
    where listing_id = p_listing_id and proposer_id = v_user_id and status = 'active'
  ) then
    raise exception 'you already have an active offer on this listing' using errcode = 'P0001';
  end if;

  -- Coin ceiling mirrors kut.get_listing_bounds -> maximum_price. A coin offer
  -- BELOW the asking price is allowed -- that is the whole point of an offer.
  select edition_id into v_edition_id from kut.user_cards where id = v_listing.card_id;
  v_discard := kut.card_discard_value(v_listing.card_id);
  v_reference := kut.market_reference_value(v_edition_id, v_discard);
  v_max_coins := greatest(100, ceil(v_reference * 5)::bigint);
  if v_offered_coins > v_max_coins then
    raise exception 'offered coins exceed the allowed maximum for this card' using errcode = '22023';
  end if;

  -- Validate the offered cards before touching any state.
  if v_card_count > 0 then
    if exists (
      select 1 from unnest(v_card_ids) as cid
      where not exists (
        select 1 from kut.user_cards c
        where c.id = cid and c.owner_id = v_user_id
          and c.burned_at is null and c.held_by_offer_id is null
      )
    ) then
      raise exception 'an offered card is not an eligible owned card' using errcode = 'P0001';
    end if;
    if exists (
      select 1 from kut.market_listings ml
      where ml.card_id = any(v_card_ids) and ml.status = 'active' and ml.expires_at > now()
    ) then
      raise exception 'an offered card has an active market listing' using errcode = 'P0001';
    end if;
  end if;

  insert into kut.wallets(user_id, balance) values (v_user_id, 0) on conflict (user_id) do nothing;
  select balance into v_balance from kut.wallets where user_id = v_user_id for update;
  if v_balance < v_offered_coins then
    raise exception 'insufficient KUT Coins to escrow this offer' using errcode = 'P0001';
  end if;

  insert into kut.trade_offers(
    listing_id, proposer_id, seller_id, offered_coins, proposer_idempotency_key, expires_at
  )
  values (
    p_listing_id, v_user_id, v_listing.seller_id, v_offered_coins, p_idempotency_key,
    now() + interval '12 hours'
  )
  returning id into v_offer_id;

  if v_card_count > 0 then
    insert into kut.trade_offer_cards(offer_id, card_id)
    select v_offer_id, cid from unnest(v_card_ids) as cid;
    update kut.user_cards set held_by_offer_id = v_offer_id where id = any(v_card_ids);
  end if;

  if v_offered_coins > 0 then
    update kut.wallets set balance = balance - v_offered_coins, updated_at = now() where user_id = v_user_id;
    insert into kut.wallet_ledger(user_id, amount, reason, reference_type, reference_id, idempotency_key)
    values (v_user_id, -v_offered_coins, 'trade_escrow', 'trade_offer', v_offer_id,
      'trade-escrow:' || v_offer_id::text);
  end if;

  select display_name into v_seller_name from kut.profiles where id = v_listing.seller_id;
  select player.display_name into v_player_name
  from kut.user_cards card
  join kut.card_editions edition on edition.id = card.edition_id
  join kut.players player on player.id = edition.player_id
  where card.id = v_listing.card_id;

  insert into kut.user_notifications(user_id, event_type, title, body, reference_type, reference_id)
  values (
    v_listing.seller_id, 'trade_offer', 'New trade offer',
    format('%s offered %s KUT Coins%s for your %s listing.',
      v_display_name, v_offered_coins,
      case when v_card_count > 0 then format(' plus %s card(s)', v_card_count) else '' end,
      v_player_name),
    'trade_offer', v_offer_id
  );

  return jsonb_build_object('offer_id', v_offer_id, 'status', 'active', 'already_processed', false);
end;
$$;

-- 8. respond_to_trade (seller accepts or rejects) -----------------------
create or replace function kut.respond_to_trade(
  p_offer_id uuid,
  p_accept boolean,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
declare
  v_user_id uuid := auth.uid();
  v_seller_name text;
  v_proposer_name text;
  v_offer record;
  v_listing record;
  v_edition_id uuid;
  v_player_name text;
  v_tax bigint;
  v_receipt bigint;
  v_other record;
  v_had_cards boolean;
begin
  if v_user_id is null then raise exception 'authentication required' using errcode = '42501'; end if;
  if p_idempotency_key is null then raise exception 'idempotency key is required' using errcode = '22023'; end if;

  select display_name into v_seller_name from kut.profiles where id = v_user_id and not is_disabled for update;
  if not found then raise exception 'active profile not found' using errcode = '42501'; end if;

  select * into v_offer from kut.trade_offers where id = p_offer_id for update;
  if not found then raise exception 'offer not found' using errcode = 'P0002'; end if;
  if v_offer.seller_id <> v_user_id then
    raise exception 'only the listing seller can respond to this offer' using errcode = '42501';
  end if;

  if v_offer.status <> 'active' then
    if v_offer.responder_idempotency_key is not distinct from p_idempotency_key then
      return jsonb_build_object('offer_id', v_offer.id, 'status', v_offer.status, 'already_processed', true);
    end if;
    raise exception 'this offer has already been resolved' using errcode = 'P0001';
  end if;

  select display_name into v_proposer_name from kut.profiles where id = v_offer.proposer_id;
  v_had_cards := exists (select 1 from kut.trade_offer_cards where offer_id = v_offer.id);

  if v_offer.expires_at <= now() then
    perform kut._refund_trade_offer(v_offer.id);
    update kut.trade_offers
      set status = 'expired', resolved_at = now(), responder_idempotency_key = p_idempotency_key
      where id = v_offer.id;
    insert into kut.user_notifications(user_id, event_type, title, body, reference_type, reference_id)
    values (v_offer.proposer_id, 'trade_response', 'Trade offer expired',
      'This offer expired before it was answered; your escrow was refunded.', 'trade_offer', v_offer.id);
    raise exception 'this offer has expired' using errcode = 'P0001';
  end if;

  -- REJECT ---------------------------------------------------------------
  if not p_accept then
    perform kut._refund_trade_offer(v_offer.id);
    update kut.trade_offers
      set status = 'rejected', resolved_at = now(), responder_idempotency_key = p_idempotency_key
      where id = v_offer.id;
    insert into kut.user_notifications(user_id, event_type, title, body, reference_type, reference_id)
    values (v_offer.proposer_id, 'trade_response', 'Trade offer declined',
      format('%s declined your trade offer; your escrow was refunded.', v_seller_name),
      'trade_offer', v_offer.id);
    return jsonb_build_object('offer_id', v_offer.id, 'status', 'rejected', 'already_processed', false);
  end if;

  -- ACCEPT -------------------------------------------------------------
  select l.id, l.card_id, l.seller_id, l.status, l.expires_at
  into v_listing
  from kut.market_listings l
  where l.id = v_offer.listing_id
  for update;
  if not found or v_listing.status <> 'active' or v_listing.expires_at <= now() then
    perform kut._refund_trade_offer(v_offer.id);
    update kut.trade_offers
      set status = 'rejected', resolved_at = now(), responder_idempotency_key = p_idempotency_key
      where id = v_offer.id;
    insert into kut.user_notifications(user_id, event_type, title, body, reference_type, reference_id)
    values (v_offer.proposer_id, 'trade_response', 'Trade offer cancelled',
      'The listing is no longer available; your escrow was refunded.', 'trade_offer', v_offer.id);
    raise exception 'listing is no longer active' using errcode = 'P0001';
  end if;

  select edition_id into v_edition_id
  from kut.user_cards
  where id = v_listing.card_id and owner_id = v_user_id and burned_at is null
  for update;
  if not found then raise exception 'you no longer own the listed card' using errcode = 'P0002'; end if;

  select player.display_name into v_player_name
  from kut.card_editions edition
  join kut.players player on player.id = edition.player_id
  where edition.id = v_edition_id;

  insert into kut.wallets(user_id, balance) values (v_user_id, 0), (v_offer.proposer_id, 0)
    on conflict (user_id) do nothing;
  -- Lock both wallets in a consistent UUID order (deadlock-safe, mirrors buy_listing).
  perform 1 from kut.wallets
  where user_id in (v_user_id, v_offer.proposer_id)
  order by user_id
  for update;

  if v_offer.offered_coins > 0 then
    v_tax := greatest(1, ceil(v_offer.offered_coins * 0.05)::bigint);
  else
    v_tax := 0;
  end if;
  v_receipt := v_offer.offered_coins - v_tax;

  -- Coins were escrowed out of the proposer's wallet at propose time. Pay the
  -- seller the receipt now; the tax stays burned.
  if v_receipt > 0 then
    update kut.wallets set balance = balance + v_receipt, updated_at = now() where user_id = v_user_id;
    insert into kut.wallet_ledger(user_id, amount, reason, reference_type, reference_id, idempotency_key)
    values (v_user_id, v_receipt, 'trade_sale', 'trade_offer', v_offer.id, 'trade-sale:' || v_offer.id::text);
  end if;

  update kut.user_cards set owner_id = v_offer.proposer_id where id = v_listing.card_id;
  update kut.user_cards set owner_id = v_user_id, held_by_offer_id = null where held_by_offer_id = v_offer.id;
  update kut.market_listings
    set status = 'sold', sold_at = now(), buyer_id = v_offer.proposer_id
    where id = v_listing.id;
  update kut.trade_offers
    set status = 'accepted', resolved_at = now(), responder_idempotency_key = p_idempotency_key,
        coins_to_seller = v_receipt, coins_burned = v_tax, settled_card_id = v_listing.card_id
    where id = v_offer.id;

  -- Auto-reject + refund every other active offer on this listing.
  for v_other in
    select id, proposer_id from kut.trade_offers
    where listing_id = v_listing.id and status = 'active' and id <> v_offer.id
    for update
  loop
    perform kut._refund_trade_offer(v_other.id);
    update kut.trade_offers set status = 'rejected', resolved_at = now() where id = v_other.id;
    insert into kut.user_notifications(user_id, event_type, title, body, reference_type, reference_id)
    values (v_other.proposer_id, 'trade_response', 'Trade offer cancelled',
      format('The %s listing was traded to another club; your escrow was refunded.', v_player_name),
      'trade_offer', v_other.id);
  end loop;

  insert into kut.user_notifications(user_id, event_type, title, body, reference_type, reference_id)
  values
    (v_offer.proposer_id, 'trade_response', 'Trade offer accepted',
      format('%s accepted your offer for %s. The card is now in your collection.', v_seller_name, v_player_name),
      'trade_offer', v_offer.id),
    (v_user_id, 'trade_response', 'Trade completed',
      format('You traded %s to %s for %s KUT Coins%s.', v_player_name, v_proposer_name,
        v_offer.offered_coins, case when v_had_cards then ' plus cards' else '' end),
      'trade_offer', v_offer.id);

  return jsonb_build_object('offer_id', v_offer.id, 'status', 'accepted',
    'coins_to_seller', v_receipt, 'coins_burned', v_tax, 'already_processed', false);
end;
$$;

-- 9. withdraw_trade (proposer cancels their own pending offer) ---------
create or replace function kut.withdraw_trade(p_offer_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
declare
  v_user_id uuid := auth.uid();
  v_offer record;
  v_proposer_name text;
  v_player_name text;
begin
  if v_user_id is null then raise exception 'authentication required' using errcode = '42501'; end if;

  select * into v_offer from kut.trade_offers where id = p_offer_id for update;
  if not found then raise exception 'offer not found' using errcode = 'P0002'; end if;
  if v_offer.proposer_id <> v_user_id then
    raise exception 'only the proposer can withdraw this offer' using errcode = '42501';
  end if;
  if v_offer.status <> 'active' then
    raise exception 'this offer is no longer active' using errcode = 'P0001';
  end if;

  perform kut._refund_trade_offer(v_offer.id);
  update kut.trade_offers set status = 'withdrawn', resolved_at = now() where id = v_offer.id;

  select display_name into v_proposer_name from kut.profiles where id = v_user_id;
  select player.display_name into v_player_name
  from kut.market_listings l
  join kut.user_cards card on card.id = l.card_id
  join kut.card_editions edition on edition.id = card.edition_id
  join kut.players player on player.id = edition.player_id
  where l.id = v_offer.listing_id;

  insert into kut.user_notifications(user_id, event_type, title, body, reference_type, reference_id)
  values (v_offer.seller_id, 'trade_response', 'Trade offer withdrawn',
    format('%s withdrew their offer%s.', v_proposer_name,
      case when v_player_name is not null then ' for ' || v_player_name else '' end),
    'trade_offer', v_offer.id);

  return jsonb_build_object('offer_id', v_offer.id, 'status', 'withdrawn');
end;
$$;

-- 10. expire_trade_offers (lazy sweep; called from the market pages + cron) --
create or replace function kut.expire_trade_offers()
returns integer
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
declare
  v_offer record;
  v_player_name text;
  v_count integer := 0;
begin
  for v_offer in
    select id, proposer_id, listing_id
    from kut.trade_offers
    where status = 'active' and expires_at <= now()
    for update skip locked
  loop
    perform kut._refund_trade_offer(v_offer.id);
    update kut.trade_offers set status = 'expired', resolved_at = now() where id = v_offer.id;

    select player.display_name into v_player_name
    from kut.market_listings l
    join kut.user_cards card on card.id = l.card_id
    join kut.card_editions edition on edition.id = card.edition_id
    join kut.players player on player.id = edition.player_id
    where l.id = v_offer.listing_id;

    insert into kut.user_notifications(user_id, event_type, title, body, reference_type, reference_id)
    values (v_offer.proposer_id, 'trade_response', 'Trade offer expired',
      format('Your offer%s expired; your escrow was refunded.',
        case when v_player_name is not null then ' for ' || v_player_name else '' end),
      'trade_offer', v_offer.id);
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

revoke execute on function kut.propose_trade(uuid, bigint, uuid[], uuid) from public, anon;
revoke execute on function kut.respond_to_trade(uuid, boolean, uuid) from public, anon;
revoke execute on function kut.withdraw_trade(uuid) from public, anon;
revoke execute on function kut.expire_trade_offers() from public, anon;
grant execute on function kut.propose_trade(uuid, bigint, uuid[], uuid) to authenticated, service_role;
grant execute on function kut.respond_to_trade(uuid, boolean, uuid) to authenticated, service_role;
grant execute on function kut.withdraw_trade(uuid) to authenticated, service_role;
grant execute on function kut.expire_trade_offers() to authenticated, service_role;

-- 11. Guard: a held card cannot be listed ------------------------------
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

  insert into kut.market_listings(card_id, seller_id, price)
  values (p_card_id, v_user_id, p_price)
  returning id into v_listing_id;
  return jsonb_build_object('listing_id', v_listing_id, 'expires_at', now() + interval '24 hours');
end;
$$;

-- 12. Guard: a held card cannot be discarded --------------------------
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

  perform 1 from kut.profiles where id = v_user_id and not is_disabled;
  if not found then
    raise exception 'active profile not found' using errcode = '42501';
  end if;

  select amount, reference_id
  into v_existing
  from kut.wallet_ledger
  where user_id = v_user_id and idempotency_key = v_ledger_key and reason = 'discard';
  if found then
    if v_existing.reference_id is distinct from p_card_id then
      raise exception 'idempotency key was already used for another card' using errcode = '22023';
    end if;
    return jsonb_build_object('card_id', p_card_id, 'coins', v_existing.amount, 'already_processed', true);
  end if;

  select
    card.id,
    card.held_by_offer_id,
    edition.is_live,
    coalesce(edition.snapshot_ovr, state.live_ovr) as ovr,
    coalesce(edition.special_discard_multiplier, 1) as special_discard_multiplier
  into v_card
  from kut.user_cards card
  join kut.card_editions edition on edition.id = card.edition_id
  left join kut.seasons active_season on active_season.is_active
  left join kut.player_season_state state
    on state.player_id = edition.player_id and state.season_id = active_season.id
  where card.id = p_card_id
    and card.owner_id = v_user_id
    and card.burned_at is null
  for update of card;

  if not found then
    select amount, reference_id
    into v_existing
    from kut.wallet_ledger
    where user_id = v_user_id and idempotency_key = v_ledger_key and reason = 'discard';
    if found and v_existing.reference_id = p_card_id then
      return jsonb_build_object('card_id', p_card_id, 'coins', v_existing.amount, 'already_processed', true);
    end if;
    raise exception 'card not found or no longer active' using errcode = 'P0002';
  end if;

  if v_card.held_by_offer_id is not null then
    raise exception 'card is committed to a pending trade offer' using errcode = 'P0001';
  end if;

  if v_card.ovr is null then
    raise exception 'card rating is unavailable' using errcode = 'P0002';
  end if;

  v_amount := round(
    10 * power(1.08::numeric, v_card.ovr - 30)
    * case when v_card.is_live then 1 else v_card.special_discard_multiplier end
  )::bigint;

  update kut.user_cards set burned_at = now() where id = v_card.id and burned_at is null;

  insert into kut.wallets (user_id, balance) values (v_user_id, 0) on conflict (user_id) do nothing;
  insert into kut.wallet_ledger (user_id, amount, reason, reference_type, reference_id, idempotency_key)
  values (v_user_id, v_amount, 'discard', 'user_card', v_card.id, v_ledger_key);
  update kut.wallets set balance = balance + v_amount, updated_at = now() where user_id = v_user_id;

  return jsonb_build_object('card_id', v_card.id, 'coins', v_amount, 'already_processed', false);
end;
$$;

-- 13. Guard: burning a held card is blocked at the trigger too ---------
create or replace function kut.prevent_burning_listed_card()
returns trigger
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
begin
  if new.burned_at is not null and old.burned_at is null then
    if exists (
      select 1 from kut.market_listings
      where card_id = old.id and status = 'active' and expires_at > now()
    ) then
      raise exception 'card has an active market listing' using errcode = 'P0001';
    end if;
    if old.held_by_offer_id is not null then
      raise exception 'card is committed to a pending trade offer' using errcode = 'P0001';
    end if;
  end if;
  return new;
end;
$$;

-- 14. Guard: cancelling a listing unwinds its pending offers -----------
create or replace function kut.cancel_listing(p_listing_id uuid)
returns void
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
declare
  v_user_id uuid := auth.uid();
  v_offer record;
begin
  if v_user_id is null then raise exception 'authentication required' using errcode = '42501'; end if;
  update kut.market_listings set status = 'cancelled', cancelled_at = now()
  where id = p_listing_id and seller_id = v_user_id and status = 'active' and expires_at > now();
  if not found then raise exception 'active listing not found' using errcode = 'P0002'; end if;

  for v_offer in
    select id, proposer_id from kut.trade_offers
    where listing_id = p_listing_id and status = 'active'
    for update
  loop
    perform kut._refund_trade_offer(v_offer.id);
    update kut.trade_offers set status = 'rejected', resolved_at = now() where id = v_offer.id;
    insert into kut.user_notifications(user_id, event_type, title, body, reference_type, reference_id)
    values (v_offer.proposer_id, 'trade_response', 'Trade offer cancelled',
      'The seller cancelled the listing; your escrow was refunded.', 'trade_offer', v_offer.id);
  end loop;
end;
$$;

-- 15. Guard: a buy-now purchase unwinds the listing's pending offers ---
create or replace function kut.buy_listing(p_listing_id uuid, p_idempotency_key uuid)
returns jsonb
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
declare
  v_buyer_id uuid := auth.uid(); v_listing record; v_sale record; v_wallet record;
  v_buyer_balance bigint; v_tax bigint; v_receipt bigint; v_sale_id uuid;
  v_player_name text; v_buyer_name text; v_offer record;
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

  -- ADR-042: a buy-now purchase cancels + refunds the listing's pending offers.
  for v_offer in
    select id, proposer_id from kut.trade_offers
    where listing_id = v_listing.id and status = 'active'
    for update
  loop
    perform kut._refund_trade_offer(v_offer.id);
    update kut.trade_offers set status = 'rejected', resolved_at = now() where id = v_offer.id;
    insert into kut.user_notifications(user_id, event_type, title, body, reference_type, reference_id)
    values (v_offer.proposer_id, 'trade_response', 'Trade offer cancelled',
      format('The %s listing was bought outright; your escrow was refunded.', v_player_name),
      'trade_offer', v_offer.id);
  end loop;

  return jsonb_build_object('sale_id', v_sale_id, 'price', v_listing.price, 'tax', v_tax, 'already_processed', false);
end;
$$;

-- 15b. Guard: an admin club reset unwinds this member's trade offers ----
-- The held-card guard (section 13) would otherwise block the reset's burn of
-- an escrowed card, and escrowed coins would be stranded. Identical to the
-- 20260905000000 body except for the trade-offer unwind block, placed before
-- the wallet snapshot so any refund to the reset member is captured in
-- v_old_balance and the ledger stays reconciled.
create or replace function kut.admin_reset_account(
  p_user_id uuid,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
declare
  v_caller_role text;
  v_target_role text;
  v_display_name text;
  v_prior record;
  v_old_balance bigint;
  v_edition_ids uuid[];
  v_burned integer;
  v_event_id uuid;
  v_offer record;
begin
  if not kut.is_admin() then
    raise exception 'admin access required' using errcode = '42501';
  end if;
  if p_user_id = auth.uid() then
    raise exception 'you cannot reset your own account' using errcode = 'P0001';
  end if;
  if p_idempotency_key is null then
    raise exception 'idempotency key is required' using errcode = '22023';
  end if;

  select role into v_caller_role from kut.profiles where id = auth.uid();
  select role, display_name into v_target_role, v_display_name
  from kut.profiles where id = p_user_id for update;
  if v_target_role is null then
    raise exception 'account not found' using errcode = 'P0002';
  end if;
  if v_target_role = 'superadmin' then
    raise exception 'superadmin accounts cannot be reset here' using errcode = 'P0001';
  end if;
  if v_target_role = 'admin' and v_caller_role <> 'superadmin' then
    raise exception 'only a superadmin can reset an administrator account' using errcode = '42501';
  end if;

  select id, amount, detail into v_prior
  from kut.admin_account_events
  where action = 'account_reset'
    and target_user_id = p_user_id
    and detail ->> 'idempotency_key' = p_idempotency_key::text
  limit 1;
  if found then
    return jsonb_build_object(
      'user_id', p_user_id,
      'display_name', v_display_name,
      'already_processed', true,
      'event_id', v_prior.id,
      'net_wallet_change', v_prior.amount
    );
  end if;

  insert into kut.wallets (user_id, balance) values (p_user_id, 0)
  on conflict (user_id) do nothing;

  -- ADR-042: unwind every active trade offer this member is party to (as
  -- proposer or seller) before the wallet snapshot below.
  for v_offer in
    select id, proposer_id from kut.trade_offers
    where status = 'active' and (proposer_id = p_user_id or seller_id = p_user_id)
    for update
  loop
    perform kut._refund_trade_offer(v_offer.id);
    update kut.trade_offers set status = 'rejected', resolved_at = now() where id = v_offer.id;
    insert into kut.user_notifications (user_id, event_type, title, body, reference_type, reference_id)
    values (v_offer.proposer_id, 'trade_response', 'Trade offer cancelled',
      'A club reset cancelled this trade offer; any escrow was refunded.', 'trade_offer', v_offer.id);
  end loop;

  select coalesce(balance, 0) into v_old_balance from kut.wallets where user_id = p_user_id for update;
  v_old_balance := coalesce(v_old_balance, 0);

  -- Cancel the member's active listings first, so the
  -- prevent_burning_listed_card trigger does not block the burn below.
  update kut.market_listings
  set status = 'cancelled', cancelled_at = now()
  where seller_id = p_user_id and status = 'active';

  update kut.user_cards set burned_at = now()
  where owner_id = p_user_id and burned_at is null;
  get diagnostics v_burned = row_count;

  delete from kut.pack_opening_cards
  where opening_id in (select id from kut.pack_openings where user_id = p_user_id);
  delete from kut.pack_openings where user_id = p_user_id;

  delete from kut.user_notifications where user_id = p_user_id;

  if v_old_balance <> 0 then
    insert into kut.wallet_ledger (user_id, amount, reason, reference_type, reference_id, idempotency_key)
    values (
      p_user_id, -v_old_balance, 'admin_reset', 'profile', p_user_id,
      'admin-reset-clear:' || p_idempotency_key::text
    );
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

  insert into kut.wallet_ledger (user_id, amount, reason, reference_type, reference_id, idempotency_key)
  values (
    p_user_id, 250, 'admin_reset', 'profile', p_user_id,
    'admin-reset-starter:' || p_idempotency_key::text
  );
  insert into kut.user_cards (edition_id, owner_id, source)
  select edition_id, p_user_id, 'starter' from unnest(v_edition_ids) as edition_id;

  update kut.wallets set balance = 250, updated_at = now() where user_id = p_user_id;

  update kut.profiles set starter_opened_at = null, updated_at = now() where id = p_user_id;

  insert into kut.admin_account_events (target_user_id, actor_id, action, amount, reason, detail)
  values (
    p_user_id, auth.uid(), 'account_reset', 250 - v_old_balance, null,
    jsonb_build_object(
      'idempotency_key', p_idempotency_key::text,
      'coins_removed', v_old_balance,
      'cards_burned', v_burned,
      'starter_edition_ids', to_jsonb(v_edition_ids)
    )
  )
  returning id into v_event_id;

  insert into kut.user_notifications (user_id, event_type, title, body, reference_type, reference_id)
  values (
    p_user_id, 'admin_notice', 'Club reset',
    'Your KUT club was reset by an admin. You''ve been given a fresh starter pack.',
    'admin_account_event', v_event_id
  );

  return jsonb_build_object(
    'user_id', p_user_id,
    'display_name', v_display_name,
    'already_processed', false,
    'event_id', v_event_id,
    'cards_burned', v_burned,
    'coins_removed', v_old_balance,
    'net_wallet_change', 250 - v_old_balance
  );
end;
$$;

revoke execute on function kut.admin_reset_account(uuid, uuid) from public, anon;
grant  execute on function kut.admin_reset_account(uuid, uuid) to authenticated;

-- 15c. Guard: a hard account deletion clears this member's trade offers --
-- trade_offers.proposer_id / seller_id are ON DELETE RESTRICT, and
-- trade_offer_cards.card_id -> user_cards is ON DELETE RESTRICT, so the
-- auth.users cascade would be blocked without this. Identical to the
-- 20260901000000 body plus the trade-offer teardown before the listing wipe.
create or replace function kut.admin_prepare_account_deletion(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
declare
  v_caller_role text;
  v_target_role text;
  v_display_name text;
  v_offer record;
begin
  if not kut.is_admin() then
    raise exception 'admin access required' using errcode = '42501';
  end if;
  if p_user_id = auth.uid() then
    raise exception 'you cannot delete your own account' using errcode = 'P0001';
  end if;

  select role into v_caller_role from kut.profiles where id = auth.uid();
  select role, display_name into v_target_role, v_display_name from kut.profiles where id = p_user_id;
  if v_target_role is null then
    raise exception 'account not found' using errcode = 'P0002';
  end if;
  if v_target_role = 'superadmin' then
    raise exception 'superadmin accounts cannot be deleted here' using errcode = 'P0001';
  end if;
  if v_target_role = 'admin' and v_caller_role <> 'superadmin' then
    raise exception 'only a superadmin can delete an administrator account' using errcode = '42501';
  end if;

  if exists (select 1 from kut.market_sales where seller_id = p_user_id or buyer_id = p_user_id)
     or exists (
       select 1 from kut.market_sales sale
       join kut.user_cards card on card.id = sale.card_id
       where card.owner_id = p_user_id
     ) then
    raise exception 'account has completed market trades - disable it instead' using errcode = 'P0001';
  end if;

  -- ADR-042: refund escrow held for other members on this account's listings,
  -- then drop every trade offer this account is party to (cascades the
  -- offered-card links; user_cards.held_by_offer_id is ON DELETE SET NULL).
  for v_offer in
    select id from kut.trade_offers where seller_id = p_user_id and status = 'active'
  loop
    perform kut._refund_trade_offer(v_offer.id);
  end loop;
  delete from kut.trade_offers where proposer_id = p_user_id or seller_id = p_user_id;

  delete from kut.market_listings
  where seller_id = p_user_id
     or buyer_id = p_user_id
     or card_id in (select id from kut.user_cards where owner_id = p_user_id);

  delete from kut.pack_opening_cards
  where opening_id in (select id from kut.pack_openings where user_id = p_user_id)
     or card_id in (select id from kut.user_cards where owner_id = p_user_id);

  delete from kut.pack_openings where user_id = p_user_id;
  delete from kut.attendance_rewards where user_id = p_user_id;
  delete from kut.password_reset_events where target_user_id = p_user_id or reset_by = p_user_id;
  delete from kut.invitations where consumed_by = p_user_id;

  return jsonb_build_object('user_id', p_user_id, 'display_name', v_display_name);
end;
$$;

revoke execute on function kut.admin_prepare_account_deletion(uuid) from public, anon;
grant  execute on function kut.admin_prepare_account_deletion(uuid) to authenticated;

-- 16. Collection projection: surface the trade-offer hold ----------------
create or replace view kut.my_collection_cards
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
  player.photo_path,
  card.held_by_offer_id
from kut.user_cards card
join kut.card_editions edition on edition.id = card.edition_id
join kut.players player on player.id = edition.player_id
left join kut.seasons active_season on active_season.is_active
left join kut.player_season_state state on state.player_id = player.id and state.season_id = active_season.id
left join kut.market_listings listing on listing.card_id = card.id and listing.status = 'active' and listing.expires_at > now()
where card.owner_id = auth.uid() and card.burned_at is null;

revoke all on kut.my_collection_cards from public;
grant select on kut.my_collection_cards to authenticated, service_role;

-- 17. my_trade_offers: the /market/offers hub projection ----------------
-- Controlled projection (security_invoker = false, bypassing RLS) filtered to
-- the two parties -- same pattern as kut.club_value_leaderboard / activity_feed.
create view kut.my_trade_offers
with (security_invoker = false, security_barrier = true)
as
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
where o.proposer_id = auth.uid() or o.seller_id = auth.uid();

revoke all on kut.my_trade_offers from public;
grant select on kut.my_trade_offers to authenticated, service_role;

-- 18. Activity feed: accepted trades surface as a 'trade' row -----------
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
