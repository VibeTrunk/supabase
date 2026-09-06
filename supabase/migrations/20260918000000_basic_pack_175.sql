-- Slice C / ADR-057: Basic packs cost 175 KUT Coins and opening is quote-safe.
-- Historical openings retain price_paid; an idempotent replay returns that value.

do $$
declare
  v_count integer;
begin
  select count(*) into v_count from kut.pack_definitions where slug = 'tfh-pack';
  if v_count <> 1 then
    raise exception 'expected exactly one tfh-pack definition, found %', v_count;
  end if;
end;
$$;

update kut.pack_definitions
set price = 175,
    updated_at = now()
where slug = 'tfh-pack';

drop function kut.open_pack(text, uuid);

create function kut.open_pack(
  p_pack_slug text,
  p_expected_price bigint,
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
  v_opening record;
  v_balance bigint;
  v_slot integer;
  v_edition_id uuid;
  v_card_id uuid;
  v_ledger_key text := 'pack:' || p_idempotency_key::text;
begin
  if v_user_id is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if p_idempotency_key is null
     or p_expected_price is null
     or p_expected_price <= 0
     or p_pack_slug !~ '^[a-z0-9]+(?:-[a-z0-9]+)*$' then
    raise exception 'valid pack, price, and idempotency key are required' using errcode = '22023';
  end if;

  perform 1 from kut.profiles where id = v_user_id and not is_disabled for update;
  if not found then
    raise exception 'active profile not found' using errcode = '42501';
  end if;

  select opening.id, opening.price_paid
  into v_opening
  from kut.pack_openings opening
  where opening.user_id = v_user_id
    and opening.idempotency_key = p_idempotency_key;
  if found then
    return jsonb_build_object(
      'opening_id', v_opening.id,
      'price_paid', v_opening.price_paid,
      'already_processed', true,
      'price_changed', false
    );
  end if;

  select id, title, price, cards_per_pack
  into v_pack
  from kut.pack_definitions
  where slug = p_pack_slug and is_active
  for share;
  if not found then
    raise exception 'active pack not found' using errcode = 'P0002';
  end if;

  if v_pack.price <> p_expected_price then
    return jsonb_build_object(
      'already_processed', false,
      'price_changed', true,
      'current_price', v_pack.price
    );
  end if;

  insert into kut.wallets (user_id, balance) values (v_user_id, 0)
  on conflict (user_id) do nothing;
  select balance into v_balance from kut.wallets where user_id = v_user_id for update;

  -- A same-key call may have waited for the wallet lock. Replay before debit.
  select opening.id, opening.price_paid
  into v_opening
  from kut.pack_openings opening
  where opening.user_id = v_user_id
    and opening.idempotency_key = p_idempotency_key;
  if found then
    return jsonb_build_object(
      'opening_id', v_opening.id,
      'price_paid', v_opening.price_paid,
      'already_processed', true,
      'price_changed', false
    );
  end if;

  if v_balance < v_pack.price then
    raise exception 'insufficient KUT Coins for this pack' using errcode = 'P0001';
  end if;

  insert into kut.pack_openings (user_id, pack_id, price_paid, idempotency_key)
  values (v_user_id, v_pack.id, v_pack.price, p_idempotency_key)
  returning id, price_paid into v_opening;

  update kut.wallets set balance = balance - v_pack.price, updated_at = now()
  where user_id = v_user_id;
  insert into kut.wallet_ledger (user_id, amount, reason, reference_type, reference_id, idempotency_key)
  values (v_user_id, -v_pack.price, 'pack_purchase', 'pack_opening', v_opening.id, v_ledger_key);

  for v_slot in 1..v_pack.cards_per_pack loop
    select candidate.id into v_edition_id
    from (
      select edition.id,
        case coalesce(state.rarity_tier, 'common')
          when 'common' then 100 when 'bronze' then 60 when 'silver' then 30
          when 'gold' then 12 when 'holo' then 4 when 'elite' then 1
        end as weight
      from kut.card_editions edition
      join kut.players player on player.id = edition.player_id
      left join kut.seasons active_season on active_season.is_active
      left join kut.player_season_state state
        on state.player_id = player.id and state.season_id = active_season.id
      where edition.is_live
        and edition.edition_type = 'live'
        and player.is_active
        and player.is_collectible
    ) candidate
    order by -ln(greatest(random(), 0.0000001)) / candidate.weight
    limit 1;

    if v_edition_id is null then
      raise exception 'no eligible Live editions are available' using errcode = 'P0002';
    end if;
    insert into kut.user_cards (edition_id, owner_id, source)
    values (v_edition_id, v_user_id, 'pack') returning id into v_card_id;
    insert into kut.pack_opening_cards (opening_id, slot, card_id)
    values (v_opening.id, v_slot, v_card_id);
    update kut.card_editions set minted_count = minted_count + 1 where id = v_edition_id;
  end loop;

  return jsonb_build_object(
    'opening_id', v_opening.id,
    'price_paid', v_opening.price_paid,
    'already_processed', false,
    'price_changed', false
  );
end;
$$;

revoke all on function kut.open_pack(text, bigint, uuid) from public, anon;
grant execute on function kut.open_pack(text, bigint, uuid) to authenticated, service_role;
