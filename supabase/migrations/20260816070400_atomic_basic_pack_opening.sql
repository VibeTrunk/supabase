create table kut.pack_definitions (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique check (slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'),
  title text not null check (char_length(title) between 1 and 80),
  price bigint not null check (price > 0),
  cards_per_pack integer not null check (cards_per_pack between 1 and 10),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

insert into kut.pack_definitions (slug, title, price, cards_per_pack)
values ('tfh-pack', 'TFH Pack', 250, 3)
on conflict (slug) do nothing;

create table kut.pack_openings (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references kut.profiles(id) on delete restrict,
  pack_id uuid not null references kut.pack_definitions(id) on delete restrict,
  price_paid bigint not null check (price_paid > 0),
  idempotency_key uuid not null,
  opened_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  unique (user_id, idempotency_key)
);

create index pack_openings_user_opened_idx on kut.pack_openings (user_id, opened_at desc);

create table kut.pack_opening_cards (
  opening_id uuid not null references kut.pack_openings(id) on delete restrict,
  slot integer not null check (slot between 1 and 10),
  card_id uuid not null unique references kut.user_cards(id) on delete restrict,
  primary key (opening_id, slot)
);

create trigger pack_definitions_set_updated_at before update on kut.pack_definitions
  for each row execute function kut.set_updated_at();

grant select on kut.pack_definitions, kut.pack_openings, kut.pack_opening_cards to authenticated, service_role;

alter table kut.pack_definitions enable row level security;
alter table kut.pack_openings enable row level security;
alter table kut.pack_opening_cards enable row level security;

create policy "members read active pack definitions" on kut.pack_definitions
  for select to authenticated using (is_active or kut.is_admin());
create policy "admins manage pack definitions" on kut.pack_definitions
  for all to authenticated using (kut.is_admin()) with check (kut.is_admin());

create policy "members read own pack openings" on kut.pack_openings
  for select to authenticated using (user_id = auth.uid());
create policy "admins read pack openings" on kut.pack_openings
  for select to authenticated using (kut.is_admin());

create policy "members read own pack result cards" on kut.pack_opening_cards
  for select to authenticated using (
    exists (
      select 1 from kut.pack_openings opening
      where opening.id = pack_opening_cards.opening_id
        and opening.user_id = auth.uid()
    )
  );
create policy "admins read pack result cards" on kut.pack_opening_cards
  for select to authenticated using (kut.is_admin());

create view kut.active_pack_offers
with (security_invoker = true, security_barrier = true)
as
select slug, title, price, cards_per_pack
from kut.pack_definitions
where is_active;

create view kut.my_pack_opening_results
with (security_invoker = true, security_barrier = true)
as
select
  opening.id as opening_id,
  opening.opened_at,
  opening.price_paid,
  pack.slug as pack_slug,
  pack.title as pack_title,
  result.slot,
  card.id as card_id,
  player.display_name,
  player.archetype,
  coalesce(edition.snapshot_ovr, state.live_ovr, 30) as ovr,
  coalesce(edition.snapshot_pac, state.pac, 30) as pac,
  coalesce(edition.snapshot_sho, state.sho, 30) as sho,
  coalesce(edition.snapshot_pas, state.pas, 30) as pas,
  coalesce(edition.snapshot_dri, state.dri, 30) as dri,
  coalesce(edition.snapshot_def, state.def, 30) as def,
  coalesce(edition.snapshot_phy, state.phy, 30) as phy,
  case
    when edition.is_live then coalesce(state.rarity_tier, 'common')
    when coalesce(edition.snapshot_ovr, 30) >= 70 then 'elite'
    when coalesce(edition.snapshot_ovr, 30) >= 60 then 'holo'
    when coalesce(edition.snapshot_ovr, 30) >= 50 then 'gold'
    when coalesce(edition.snapshot_ovr, 30) >= 40 then 'silver'
    when coalesce(edition.snapshot_ovr, 30) >= 30 then 'bronze'
    else 'common'
  end as rarity_tier
from kut.pack_openings opening
join kut.pack_definitions pack on pack.id = opening.pack_id
join kut.pack_opening_cards result on result.opening_id = opening.id
join kut.user_cards card on card.id = result.card_id
join kut.card_editions edition on edition.id = card.edition_id
join kut.players player on player.id = edition.player_id
left join kut.seasons active_season on active_season.is_active
left join kut.player_season_state state
  on state.player_id = player.id
  and state.season_id = active_season.id
where opening.user_id = auth.uid();

revoke all on kut.active_pack_offers, kut.my_pack_opening_results from public;
grant select on kut.active_pack_offers, kut.my_pack_opening_results to authenticated, service_role;

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

    insert into kut.user_cards (edition_id, owner_id, is_tradeable, source)
    values (v_edition_id, v_user_id, true, 'pack')
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

revoke execute on function kut.open_pack(text, uuid) from public, anon;
grant execute on function kut.open_pack(text, uuid) to authenticated, service_role;
