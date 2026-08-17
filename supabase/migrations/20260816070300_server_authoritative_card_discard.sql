create or replace view kut.my_collection_cards
with (security_invoker = true, security_barrier = true)
as
select
  card.id as card_id,
  card.edition_id,
  card.is_tradeable,
  card.source,
  card.acquired_at,
  edition.title as edition_title,
  edition.edition_type,
  edition.is_live,
  player.id as player_id,
  player.slug as player_slug,
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
  end as rarity_tier,
  round(
    10 * power(1.08::numeric, coalesce(edition.snapshot_ovr, state.live_ovr, 30) - 30)
    * case when edition.is_live then 1 else coalesce(edition.special_discard_multiplier, 1) end
  )::bigint as discard_value
from kut.user_cards card
join kut.card_editions edition on edition.id = card.edition_id
join kut.players player on player.id = edition.player_id
left join kut.seasons active_season on active_season.is_active
left join kut.player_season_state state
  on state.player_id = player.id
  and state.season_id = active_season.id
where card.owner_id = auth.uid()
  and card.burned_at is null;

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
    card.is_tradeable,
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

  if not v_card.is_tradeable then
    raise exception 'card is not eligible for discard' using errcode = 'P0001';
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

revoke execute on function kut.discard_card(uuid, uuid) from public, anon;
grant execute on function kut.discard_card(uuid, uuid) to authenticated, service_role;
