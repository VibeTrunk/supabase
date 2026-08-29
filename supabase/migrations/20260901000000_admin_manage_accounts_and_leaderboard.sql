-- Admin account management + leaderboard change. See ADR-030.
--
--   1. kut.club_value_leaderboard excludes accounts with admin privileges
--      (role <> 'user'). my_club_value is unchanged, so an admin still sees
--      their own summary on /club — they just don't appear in the public rank.
--   2. kut.admin_set_account_disabled(uuid, boolean) -- soft, reversible. A
--      disabled account cannot sign in and drops out of the leaderboard.
--   3. kut.admin_prepare_account_deletion(uuid) -- authorizes + clears the
--      ON DELETE RESTRICT rows that would otherwise block removing the
--      account, so the server action can then call the Auth admin API to
--      delete auth.users (which cascades profiles → wallets, wallet_ledger,
--      user_cards, user_notifications). Refused for an account that has any
--      completed market trade — disable those instead.
--
-- Rollback:
--   drop function kut.admin_set_account_disabled(uuid, boolean);
--   drop function kut.admin_prepare_account_deletion(uuid);
--   -- restore kut.club_value_leaderboard to its 20260817010001 body (drop the
--   -- `and profile.role = 'user'` predicate).

-- 1. Leaderboard: members only -----------------------------------------------
create or replace view kut.club_value_leaderboard
with (security_invoker = false, security_barrier = true)
as
with recent_sales as (
  select edition_id, count(*) as sale_count,
    percentile_cont(0.5) within group (order by sale_price) as median_sale
  from kut.market_sales
  where sold_at >= now() - interval '14 days'
  group by edition_id
), card_values as (
  select card.owner_id, edition.player_id,
    case when coalesce(recent_sales.sale_count, 0) >= 5 then
      greatest(discard_values.discard_value, least(round(recent_sales.median_sale)::bigint, discard_values.discard_value * 6))
    else round(discard_values.discard_value * 1.5)::bigint end as reference_value
  from kut.user_cards card
  join kut.card_editions edition on edition.id = card.edition_id
  left join kut.seasons active_season on active_season.is_active
  left join kut.player_season_state state on state.player_id = edition.player_id and state.season_id = active_season.id
  left join recent_sales on recent_sales.edition_id = edition.id
  cross join lateral (
    select round(10 * power(1.08::numeric, coalesce(edition.snapshot_ovr, state.live_ovr, 30) - 30) * case when edition.is_live then 1 else coalesce(edition.special_discard_multiplier, 1) end)::bigint as discard_value
  ) discard_values
  where card.burned_at is null
), club_totals as (
  select profile.id, profile.display_name, coalesce(wallet.balance, 0)::bigint as wallet_balance,
    count(card_values.reference_value)::integer as card_count,
    count(distinct card_values.player_id)::integer as unique_player_count,
    coalesce(sum(card_values.reference_value), 0)::bigint as card_value
  from kut.profiles profile
  left join kut.wallets wallet on wallet.user_id = profile.id
  left join card_values on card_values.owner_id = profile.id
  where not profile.is_disabled and profile.role = 'user'
  group by profile.id, profile.display_name, wallet.balance
)
select rank() over (order by (wallet_balance + card_value) desc, display_name asc)::integer as rank,
  display_name, display_name || '''s Club' as club_name,
  (wallet_balance + card_value)::bigint as club_value,
  card_count, unique_player_count, id = auth.uid() as is_current_user
from club_totals;

revoke all on kut.club_value_leaderboard from public;
grant select on kut.club_value_leaderboard to authenticated, service_role;

-- 2. Soft disable / enable -------------------------------------------------
create or replace function kut.admin_set_account_disabled(p_user_id uuid, p_disabled boolean)
returns jsonb
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
declare
  v_caller_role text;
  v_target_role text;
  v_display_name text;
begin
  if not kut.is_admin() then
    raise exception 'admin access required' using errcode = '42501';
  end if;
  if p_user_id = auth.uid() then
    raise exception 'you cannot change your own account here' using errcode = 'P0001';
  end if;

  select role into v_caller_role from kut.profiles where id = auth.uid();
  select role, display_name into v_target_role, v_display_name from kut.profiles where id = p_user_id;
  if v_target_role is null then
    raise exception 'account not found' using errcode = 'P0002';
  end if;
  if v_target_role = 'superadmin' then
    raise exception 'superadmin accounts cannot be changed here' using errcode = 'P0001';
  end if;
  if v_target_role = 'admin' and v_caller_role <> 'superadmin' then
    raise exception 'only a superadmin can change an administrator account' using errcode = '42501';
  end if;

  update kut.profiles set is_disabled = p_disabled, updated_at = now() where id = p_user_id;

  return jsonb_build_object('user_id', p_user_id, 'is_disabled', p_disabled, 'display_name', v_display_name);
end;
$$;

revoke execute on function kut.admin_set_account_disabled(uuid, boolean) from public, anon;
grant  execute on function kut.admin_set_account_disabled(uuid, boolean) to authenticated;

-- 3. Prepare a hard account deletion ----------------------------------------
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

  -- Completed trades are irreversible cross-member economy history.
  if exists (select 1 from kut.market_sales where seller_id = p_user_id or buyer_id = p_user_id)
     or exists (
       select 1 from kut.market_sales sale
       join kut.user_cards card on card.id = sale.card_id
       where card.owner_id = p_user_id
     ) then
    raise exception 'account has completed market trades - disable it instead' using errcode = 'P0001';
  end if;

  -- Clear the ON DELETE RESTRICT references so auth.users deletion can cascade.
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
