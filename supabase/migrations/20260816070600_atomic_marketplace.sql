create table kut.market_listings (
  id uuid primary key default gen_random_uuid(),
  card_id uuid not null references kut.user_cards(id) on delete restrict,
  seller_id uuid not null references kut.profiles(id) on delete restrict,
  price bigint not null check (price > 0),
  status text not null default 'active' check (status in ('active', 'sold', 'cancelled', 'expired')),
  listed_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '24 hours'),
  cancelled_at timestamptz,
  sold_at timestamptz,
  buyer_id uuid references kut.profiles(id) on delete restrict,
  check (expires_at > listed_at),
  check ((status = 'sold') = (sold_at is not null and buyer_id is not null)),
  check ((status = 'cancelled') = (cancelled_at is not null))
);

create unique index market_listings_one_active_card_idx
  on kut.market_listings(card_id) where status = 'active';
create index market_listings_active_browse_idx
  on kut.market_listings(status, expires_at, listed_at desc);

create table kut.market_sales (
  id uuid primary key default gen_random_uuid(),
  listing_id uuid not null unique references kut.market_listings(id) on delete restrict,
  card_id uuid not null references kut.user_cards(id) on delete restrict,
  edition_id uuid not null references kut.card_editions(id) on delete restrict,
  seller_id uuid not null references kut.profiles(id) on delete restrict,
  buyer_id uuid not null references kut.profiles(id) on delete restrict,
  sale_price bigint not null check (sale_price > 0),
  tax_amount bigint not null check (tax_amount >= 1),
  seller_receipt bigint not null check (seller_receipt >= 0),
  buyer_idempotency_key uuid not null,
  sold_at timestamptz not null default now(),
  check (seller_id <> buyer_id),
  check (seller_receipt + tax_amount = sale_price),
  unique (buyer_id, buyer_idempotency_key)
);

create index market_sales_edition_sold_idx on kut.market_sales(edition_id, sold_at desc);

grant select on kut.market_listings, kut.market_sales to authenticated, service_role;

alter table kut.market_listings enable row level security;
alter table kut.market_sales enable row level security;

create policy "members read active or own listings" on kut.market_listings
  for select to authenticated using (
    (status = 'active' and expires_at > now()) or seller_id = auth.uid() or kut.is_admin()
  );
create policy "members read own market sales" on kut.market_sales
  for select to authenticated using (seller_id = auth.uid() or buyer_id = auth.uid() or kut.is_admin());

create or replace function kut.card_discard_value(p_card_id uuid)
returns bigint
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
declare
  v_ovr integer;
  v_is_live boolean;
  v_multiplier numeric;
begin
  select coalesce(edition.snapshot_ovr, state.live_ovr), edition.is_live, coalesce(edition.special_discard_multiplier, 1)
  into v_ovr, v_is_live, v_multiplier
  from kut.user_cards card
  join kut.card_editions edition on edition.id = card.edition_id
  left join kut.seasons active_season on active_season.is_active
  left join kut.player_season_state state on state.player_id = edition.player_id and state.season_id = active_season.id
  where card.id = p_card_id;

  if v_ovr is null then
    raise exception 'card rating is unavailable' using errcode = 'P0002';
  end if;

  return round(10 * power(1.08::numeric, v_ovr - 30) * case when v_is_live then 1 else v_multiplier end)::bigint;
end;
$$;

create or replace function kut.market_reference_value(p_edition_id uuid, p_discard_value bigint)
returns bigint
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
declare
  v_sale_count integer;
  v_median numeric;
begin
  select count(*), percentile_cont(0.5) within group (order by sale_price)
  into v_sale_count, v_median
  from kut.market_sales
  where edition_id = p_edition_id
    and sold_at >= now() - interval '14 days';

  if v_sale_count >= 5 then
    return greatest(p_discard_value, least(round(v_median)::bigint, p_discard_value * 6));
  end if;

  return round(p_discard_value * 1.5)::bigint;
end;
$$;

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
  where id = p_card_id and owner_id = v_user_id and burned_at is null and is_tradeable;
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

  select id, is_tradeable into v_card from kut.user_cards
  where id = p_card_id and owner_id = v_user_id and burned_at is null for update;
  if not found or not v_card.is_tradeable then raise exception 'card is not eligible for listing' using errcode = 'P0001'; end if;
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

create or replace function kut.cancel_listing(p_listing_id uuid)
returns void
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
declare v_user_id uuid := auth.uid(); begin
  if v_user_id is null then raise exception 'authentication required' using errcode = '42501'; end if;
  update kut.market_listings set status = 'cancelled', cancelled_at = now()
  where id = p_listing_id and seller_id = v_user_id and status = 'active' and expires_at > now();
  if not found then raise exception 'active listing not found' using errcode = 'P0002'; end if;
end;
$$;

create or replace function kut.buy_listing(p_listing_id uuid, p_idempotency_key uuid)
returns jsonb
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
declare
  v_buyer_id uuid := auth.uid();
  v_listing record;
  v_sale record;
  v_wallet record;
  v_buyer_balance bigint;
  v_tax bigint;
  v_receipt bigint;
  v_sale_id uuid;
begin
  if v_buyer_id is null then raise exception 'authentication required' using errcode = '42501'; end if;
  if p_idempotency_key is null then raise exception 'idempotency key is required' using errcode = '22023'; end if;
  perform 1 from kut.profiles where id = v_buyer_id and not is_disabled for update;
  if not found then raise exception 'active profile not found' using errcode = '42501'; end if;

  select id, listing_id, sale_price into v_sale from kut.market_sales
  where buyer_id = v_buyer_id and buyer_idempotency_key = p_idempotency_key;
  if found then
    if v_sale.listing_id <> p_listing_id then raise exception 'idempotency key was already used for another listing' using errcode = '22023'; end if;
    return jsonb_build_object('sale_id', v_sale.id, 'price', v_sale.sale_price, 'already_processed', true);
  end if;

  select id, card_id, seller_id, price, status, expires_at into v_listing
  from kut.market_listings where id = p_listing_id for update;
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
  if v_buyer_balance < v_listing.price then raise exception 'insufficient TF Coins for this listing' using errcode = 'P0001'; end if;

  perform 1 from kut.user_cards where id = v_listing.card_id and owner_id = v_listing.seller_id and burned_at is null and is_tradeable for update;
  if not found then raise exception 'seller no longer owns an eligible card' using errcode = 'P0002'; end if;

  v_tax := greatest(1, ceil(v_listing.price * 0.05)::bigint);
  v_receipt := v_listing.price - v_tax;
  insert into kut.market_sales(listing_id, card_id, edition_id, seller_id, buyer_id, sale_price, tax_amount, seller_receipt, buyer_idempotency_key)
  select v_listing.id, card.id, card.edition_id, v_listing.seller_id, v_buyer_id, v_listing.price, v_tax, v_receipt, p_idempotency_key
  from kut.user_cards card where card.id = v_listing.card_id
  returning id into v_sale_id;

  update kut.wallets set balance = balance - v_listing.price, updated_at = now() where user_id = v_buyer_id;
  update kut.wallets set balance = balance + v_receipt, updated_at = now() where user_id = v_listing.seller_id;
  insert into kut.wallet_ledger(user_id, amount, reason, reference_type, reference_id, idempotency_key) values
    (v_buyer_id, -v_receipt, 'market_buy', 'market_sale', v_sale_id, 'market-buy:' || p_idempotency_key::text),
    (v_buyer_id, -v_tax, 'market_tax', 'market_sale', v_sale_id, 'market-tax:' || p_idempotency_key::text),
    (v_listing.seller_id, v_receipt, 'market_sale', 'market_sale', v_sale_id, 'market-sale:' || v_sale_id::text);
  update kut.user_cards set owner_id = v_buyer_id where id = v_listing.card_id;
  update kut.market_listings set status = 'sold', sold_at = now(), buyer_id = v_buyer_id where id = v_listing.id;
  return jsonb_build_object('sale_id', v_sale_id, 'price', v_listing.price, 'tax', v_tax, 'already_processed', false);
end;
$$;

create or replace function kut.prevent_burning_listed_card()
returns trigger language plpgsql security definer set search_path = kut, pg_catalog as $$
begin
  if new.burned_at is not null and old.burned_at is null and exists (
    select 1 from kut.market_listings where card_id = old.id and status = 'active' and expires_at > now()
  ) then raise exception 'card has an active market listing' using errcode = 'P0001'; end if;
  return new;
end;
$$;
create trigger user_cards_prevent_burning_listed_card before update of burned_at on kut.user_cards
  for each row execute function kut.prevent_burning_listed_card();

create or replace view kut.my_collection_cards
with (security_invoker = true, security_barrier = true)
as
select card.id as card_id, card.edition_id, card.is_tradeable, card.source, card.acquired_at,
  edition.title as edition_title, edition.edition_type, edition.is_live,
  player.id as player_id, player.slug as player_slug, player.display_name, player.archetype,
  coalesce(edition.snapshot_ovr, state.live_ovr, 30) as ovr,
  coalesce(edition.snapshot_pac, state.pac, 30) as pac, coalesce(edition.snapshot_sho, state.sho, 30) as sho,
  coalesce(edition.snapshot_pas, state.pas, 30) as pas, coalesce(edition.snapshot_dri, state.dri, 30) as dri,
  coalesce(edition.snapshot_def, state.def, 30) as def, coalesce(edition.snapshot_phy, state.phy, 30) as phy,
  case when edition.is_live then coalesce(state.rarity_tier, 'common') when coalesce(edition.snapshot_ovr, 30) >= 70 then 'elite' when coalesce(edition.snapshot_ovr, 30) >= 60 then 'holo' when coalesce(edition.snapshot_ovr, 30) >= 50 then 'gold' when coalesce(edition.snapshot_ovr, 30) >= 40 then 'silver' when coalesce(edition.snapshot_ovr, 30) >= 30 then 'bronze' else 'common' end as rarity_tier,
  round(10 * power(1.08::numeric, coalesce(edition.snapshot_ovr, state.live_ovr, 30) - 30) * case when edition.is_live then 1 else coalesce(edition.special_discard_multiplier, 1) end)::bigint as discard_value,
  listing.id as active_listing_id, listing.price as active_listing_price, listing.expires_at as active_listing_expires_at
from kut.user_cards card
join kut.card_editions edition on edition.id = card.edition_id
join kut.players player on player.id = edition.player_id
left join kut.seasons active_season on active_season.is_active
left join kut.player_season_state state on state.player_id = player.id and state.season_id = active_season.id
left join kut.market_listings listing on listing.card_id = card.id and listing.status = 'active' and listing.expires_at > now()
where card.owner_id = auth.uid() and card.burned_at is null;

create view kut.active_market_listings
with (security_invoker = false, security_barrier = true)
as
select listing.id as listing_id, listing.price, listing.listed_at, listing.expires_at,
  card.id as card_id, edition.id as edition_id, player.display_name, player.archetype,
  coalesce(edition.snapshot_ovr, state.live_ovr, 30) as ovr,
  coalesce(edition.snapshot_pac, state.pac, 30) as pac, coalesce(edition.snapshot_sho, state.sho, 30) as sho,
  coalesce(edition.snapshot_pas, state.pas, 30) as pas, coalesce(edition.snapshot_dri, state.dri, 30) as dri,
  coalesce(edition.snapshot_def, state.def, 30) as def, coalesce(edition.snapshot_phy, state.phy, 30) as phy,
  case when edition.is_live then coalesce(state.rarity_tier, 'common') when coalesce(edition.snapshot_ovr, 30) >= 70 then 'elite' when coalesce(edition.snapshot_ovr, 30) >= 60 then 'holo' when coalesce(edition.snapshot_ovr, 30) >= 50 then 'gold' when coalesce(edition.snapshot_ovr, 30) >= 40 then 'silver' when coalesce(edition.snapshot_ovr, 30) >= 30 then 'bronze' else 'common' end as rarity_tier
from kut.market_listings listing
join kut.user_cards card on card.id = listing.card_id
join kut.card_editions edition on edition.id = card.edition_id
join kut.players player on player.id = edition.player_id
left join kut.seasons active_season on active_season.is_active
left join kut.player_season_state state on state.player_id = player.id and state.season_id = active_season.id
where listing.status = 'active' and listing.expires_at > now() and card.burned_at is null;

revoke execute on function kut.card_discard_value(uuid), kut.market_reference_value(uuid, bigint) from public, anon, authenticated;
revoke execute on function kut.get_listing_bounds(uuid), kut.create_listing(uuid, bigint), kut.cancel_listing(uuid), kut.buy_listing(uuid, uuid) from public, anon;
grant execute on function kut.get_listing_bounds(uuid), kut.create_listing(uuid, bigint), kut.cancel_listing(uuid), kut.buy_listing(uuid, uuid) to authenticated, service_role;
revoke all on kut.active_market_listings from public;
grant select on kut.active_market_listings to authenticated, service_role;
