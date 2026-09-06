-- Slice D / ADR-058: private wants plus explicit copy-level trade availability.
-- Discovery only: no matching, reservation, transfer, escrow, wallet, or notification path.

create table kut.card_wants (
  user_id uuid not null references kut.profiles(id) on delete cascade,
  edition_id uuid not null references kut.card_editions(id) on delete cascade,
  state text not null default 'active' check (state in ('active', 'fulfilled')),
  created_at timestamptz not null default now(),
  fulfilled_at timestamptz,
  primary key (user_id, edition_id),
  check ((state = 'fulfilled') = (fulfilled_at is not null))
);

create table kut.trade_availability (
  card_id uuid primary key references kut.user_cards(id) on delete cascade,
  owner_id uuid not null references kut.profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);
create index trade_availability_owner_idx on kut.trade_availability(owner_id);

alter table kut.card_wants enable row level security;
alter table kut.trade_availability enable row level security;
create policy "members read own card wants" on kut.card_wants
  for select to authenticated using (user_id = auth.uid() or kut.is_admin());
create policy "members read own trade availability" on kut.trade_availability
  for select to authenticated using (owner_id = auth.uid() or kut.is_admin());
grant select on kut.card_wants, kut.trade_availability to authenticated, service_role;
revoke insert, update, delete on kut.card_wants, kut.trade_availability from authenticated;

create or replace function kut.set_card_want(p_edition_id uuid, p_wanted boolean)
returns jsonb
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
declare
  v_user_id uuid := auth.uid();
  v_count integer;
begin
  if v_user_id is null then raise exception 'authentication required' using errcode = '42501'; end if;
  if p_edition_id is null or p_wanted is null then raise exception 'edition and wanted are required' using errcode = '22023'; end if;
  perform 1 from kut.profiles where id = v_user_id and not is_disabled for update;
  if not found then raise exception 'active profile not found' using errcode = '42501'; end if;
  perform 1
  from kut.card_editions e join kut.players p on p.id = e.player_id
  where e.id = p_edition_id and p.is_active and p.is_collectible
    and (e.is_live or (e.issued_at is not null and e.issued_at <= now()
      and (e.pack_available_from is null or e.pack_available_from <= now())
      and (e.pack_available_until is null or e.pack_available_until > now())));
  if not found then raise exception 'edition is not selectable' using errcode = 'P0002'; end if;

  if p_wanted then
    select count(*) into v_count from kut.card_wants where user_id = v_user_id and state = 'active';
    if v_count >= 100 and not exists (
      select 1 from kut.card_wants where user_id = v_user_id and edition_id = p_edition_id and state = 'active'
    ) then raise exception 'wanted-card limit reached' using errcode = 'P0001'; end if;
    insert into kut.card_wants(user_id, edition_id, state, fulfilled_at)
    values (v_user_id, p_edition_id, 'active', null)
    on conflict (user_id, edition_id) do update set state = 'active', fulfilled_at = null;
  else
    delete from kut.card_wants where user_id = v_user_id and edition_id = p_edition_id;
  end if;
  return jsonb_build_object('edition_id', p_edition_id, 'wanted', p_wanted);
end;
$$;

create or replace function kut.set_trade_availability(p_card_id uuid, p_available boolean)
returns jsonb
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
declare
  v_user_id uuid := auth.uid();
  v_count integer;
begin
  if v_user_id is null then raise exception 'authentication required' using errcode = '42501'; end if;
  if p_card_id is null or p_available is null then raise exception 'card and availability are required' using errcode = '22023'; end if;
  perform 1 from kut.profiles where id = v_user_id and not is_disabled for update;
  if not found then raise exception 'active profile not found' using errcode = '42501'; end if;

  if p_available then
    perform 1 from kut.user_cards card
    where card.id = p_card_id and card.owner_id = v_user_id
      and card.burned_at is null and card.held_by_offer_id is null
      and not exists (
        select 1 from kut.market_listings listing
        where listing.card_id = card.id and listing.status = 'active' and listing.expires_at > now()
      )
    for update;
    if not found then raise exception 'card is not eligible to share' using errcode = 'P0001'; end if;
    select count(*) into v_count from kut.trade_availability where owner_id = v_user_id;
    if v_count >= 30 and not exists (select 1 from kut.trade_availability where card_id = p_card_id) then
      raise exception 'trade-availability limit reached' using errcode = 'P0001';
    end if;
    insert into kut.trade_availability(card_id, owner_id) values (p_card_id, v_user_id)
    on conflict (card_id) do update set owner_id = excluded.owner_id;
  else
    delete from kut.trade_availability where card_id = p_card_id and owner_id = v_user_id;
  end if;
  return jsonb_build_object('card_id', p_card_id, 'available', p_available);
end;
$$;

create function kut._maintain_trade_discovery_for_card()
returns trigger language plpgsql security definer set search_path = kut, pg_catalog as $$
begin
  if tg_op = 'DELETE' then
    delete from kut.trade_availability where card_id = old.id;
    return old;
  end if;
  if new.burned_at is not null or new.held_by_offer_id is not null or new.owner_id is distinct from old.owner_id then
    delete from kut.trade_availability where card_id = new.id;
  end if;
  if tg_op = 'INSERT' or new.owner_id is distinct from old.owner_id then
    update kut.card_wants set state = 'fulfilled', fulfilled_at = now()
    where user_id = new.owner_id and edition_id = new.edition_id and state = 'active';
  end if;
  return new;
end;
$$;
create trigger user_cards_trade_discovery
after insert or update of owner_id, burned_at, held_by_offer_id or delete on kut.user_cards
for each row execute function kut._maintain_trade_discovery_for_card();

create function kut._clear_availability_for_listing()
returns trigger language plpgsql security definer set search_path = kut, pg_catalog as $$
begin
  if new.status = 'active' and new.expires_at > now() then
    delete from kut.trade_availability where card_id = new.card_id;
  end if;
  return new;
end;
$$;
create trigger market_listing_clears_trade_availability
after insert or update of status, expires_at on kut.market_listings
for each row execute function kut._clear_availability_for_listing();

create view kut.my_wanted_cards
with (security_invoker = true, security_barrier = true) as
select w.edition_id, w.state, w.created_at, w.fulfilled_at,
  e.title as edition_title, e.edition_type, e.is_live,
  p.id as player_id, p.slug as player_slug, p.display_name,
  count(card.id)::integer as owned_count,
  listing.lowest_listing_price
from kut.card_wants w
join kut.card_editions e on e.id = w.edition_id
join kut.players p on p.id = e.player_id
left join kut.user_cards card on card.edition_id = w.edition_id and card.owner_id = auth.uid() and card.burned_at is null
left join lateral (
  select min(l.price) as lowest_listing_price
  from kut.market_listings l
  join kut.user_cards listed_card on listed_card.id = l.card_id
  where listed_card.edition_id = w.edition_id
    and l.status = 'active' and l.expires_at > now()
) listing on true
where w.user_id = auth.uid()
group by w.edition_id, w.state, w.created_at, w.fulfilled_at, e.title, e.edition_type, e.is_live, p.id, p.slug, p.display_name, listing.lowest_listing_price;

create view kut.my_trade_cards
with (security_invoker = true, security_barrier = true) as
select card.id as card_id, card.edition_id, e.title as edition_title, e.edition_type,
  p.display_name, card.acquired_at,
  (availability.card_id is not null) as is_available,
  case when card.burned_at is not null then 'unavailable'
    when card.held_by_offer_id is not null then 'held'
    when exists (select 1 from kut.market_listings l where l.card_id = card.id and l.status = 'active' and l.expires_at > now()) then 'listed'
    else 'eligible' end as availability_state
from kut.user_cards card
join kut.card_editions e on e.id = card.edition_id
join kut.players p on p.id = e.player_id
left join kut.trade_availability availability on availability.card_id = card.id and availability.owner_id = auth.uid()
where card.owner_id = auth.uid() and card.burned_at is null;

create function kut.get_my_wanted_availability()
returns table(
  edition_id uuid,
  owner_display_name text
)
language sql stable security definer set search_path = kut, pg_catalog as $$
  select distinct w.edition_id, owner_profile.display_name
  from kut.card_wants w
  join kut.trade_availability availability on true
  join kut.user_cards card on card.id = availability.card_id
  join kut.profiles owner_profile on owner_profile.id = availability.owner_id
  where w.user_id = auth.uid() and w.state = 'active'
    and card.edition_id = w.edition_id
    and card.owner_id = availability.owner_id
    and availability.owner_id <> auth.uid()
    and card.burned_at is null and card.held_by_offer_id is null
    and not owner_profile.is_disabled
    and not exists (
      select 1 from kut.market_listings listing
      where listing.card_id = card.id and listing.status = 'active' and listing.expires_at > now()
    )
  order by w.edition_id, owner_profile.display_name;
$$;

revoke all on function kut.set_card_want(uuid, boolean), kut.set_trade_availability(uuid, boolean), kut.get_my_wanted_availability() from public, anon;
grant execute on function kut.set_card_want(uuid, boolean), kut.set_trade_availability(uuid, boolean), kut.get_my_wanted_availability() to authenticated, service_role;
revoke all on kut.my_wanted_cards, kut.my_trade_cards from public, anon;
grant select on kut.my_wanted_cards, kut.my_trade_cards to authenticated, service_role;
