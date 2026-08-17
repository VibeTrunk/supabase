create table kut.user_notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references kut.profiles(id) on delete cascade,
  event_type text not null check (event_type in ('market_sale', 'market_purchase', 'attendance_reward', 'pack_opened', 'admin_notice')),
  title text not null check (char_length(title) between 1 and 120),
  body text not null check (char_length(body) between 1 and 500),
  reference_type text,
  reference_id uuid,
  read_at timestamptz,
  created_at timestamptz not null default now()
);

create index user_notifications_inbox_idx on kut.user_notifications(user_id, read_at, created_at desc);
create unique index user_notifications_event_once_idx
  on kut.user_notifications(user_id, event_type, reference_type, reference_id)
  where reference_type is not null and reference_id is not null;

grant select on kut.user_notifications to authenticated, service_role;
alter table kut.user_notifications enable row level security;
create policy "members read own notifications" on kut.user_notifications
  for select to authenticated using (user_id = auth.uid());

create or replace function kut.mark_notifications_read(p_notification_ids uuid[] default null)
returns integer
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
declare
  v_user_id uuid := auth.uid();
  v_count integer;
begin
  if v_user_id is null then raise exception 'authentication required' using errcode = '42501'; end if;
  perform 1 from kut.profiles where id = v_user_id and not is_disabled;
  if not found then raise exception 'active profile not found' using errcode = '42501'; end if;

  update kut.user_notifications
  set read_at = now()
  where user_id = v_user_id
    and read_at is null
    and (p_notification_ids is null or id = any(p_notification_ids));
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

create or replace function kut.buy_listing(p_listing_id uuid, p_idempotency_key uuid)
returns jsonb
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
declare
  v_buyer_id uuid := auth.uid(); v_listing record; v_sale record; v_wallet record;
  v_buyer_balance bigint; v_tax bigint; v_receipt bigint; v_sale_id uuid; v_player_name text;
begin
  if v_buyer_id is null then raise exception 'authentication required' using errcode = '42501'; end if;
  if p_idempotency_key is null then raise exception 'idempotency key is required' using errcode = '22023'; end if;
  perform 1 from kut.profiles where id = v_buyer_id and not is_disabled for update;
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
  where card.id = v_listing.card_id and card.owner_id = v_listing.seller_id and card.burned_at is null and card.is_tradeable
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
    (v_listing.seller_id, 'market_sale', 'Card sold', format('Your %s card sold for %s TF Coins. You received %s TF Coins after tax.', v_player_name, v_listing.price, v_receipt), 'market_sale', v_sale_id);
  return jsonb_build_object('sale_id', v_sale_id, 'price', v_listing.price, 'tax', v_tax, 'already_processed', false);
end;
$$;

-- Bring the local market history into the new inbox once. The unique index
-- makes this safe if a migration is ever replayed in a restored environment.
insert into kut.user_notifications(user_id, event_type, title, body, reference_type, reference_id, created_at)
select sale.buyer_id, 'market_purchase', 'Card bought',
  format('You bought %s for %s TF Coins.', player.display_name, sale.sale_price),
  'market_sale', sale.id, sale.sold_at
from kut.market_sales sale
join kut.card_editions edition on edition.id = sale.edition_id
join kut.players player on player.id = edition.player_id
on conflict (user_id, event_type, reference_type, reference_id) where reference_type is not null and reference_id is not null do nothing;

insert into kut.user_notifications(user_id, event_type, title, body, reference_type, reference_id, created_at)
select sale.seller_id, 'market_sale', 'Card sold',
  format('Your %s card sold for %s TF Coins. You received %s TF Coins after tax.', player.display_name, sale.sale_price, sale.seller_receipt),
  'market_sale', sale.id, sale.sold_at
from kut.market_sales sale
join kut.card_editions edition on edition.id = sale.edition_id
join kut.players player on player.id = edition.player_id
on conflict (user_id, event_type, reference_type, reference_id) where reference_type is not null and reference_id is not null do nothing;

revoke execute on function kut.mark_notifications_read(uuid[]) from public, anon;
grant execute on function kut.mark_notifications_read(uuid[]) to authenticated, service_role;
