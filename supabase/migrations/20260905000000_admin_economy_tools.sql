-- Batch D (tester feedback #8 + #6), ADR-035: two admin economy tools.
--
--   1. kut.admin_adjust_wallet(p_user_id uuid, p_amount bigint, p_reason text)
--      -- an audited coin faucet. An admin credits (+) or claws back (-) KUT
--      Coins from any member's wallet, ledger-backed (reason 'admin_grant'),
--      capped at abs(amount) <= ECONOMY.adminWalletAdjustMax (100000), never
--      below zero, with a required 1-200 char reason. Writes an admin_notice
--      inbox row and a kut.admin_account_events audit row.
--   2. kut.admin_reset_account(p_user_id uuid, p_idempotency_key uuid) -- a
--      soft reset. Wipes the member's economy state (wallet, owned cards, pack
--      history, notifications) and re-grants the standard starter (250 + 3
--      random Live cards), but KEEPS the login/username/profile/player link and
--      every cross-member trade row (market_sales, market_listings, the market
--      wallet_ledger entries) and every attendance_rewards guard row. Replays
--      the /welcome starter reveal (starter_opened_at -> null, starter_claimed_at
--      kept). Idempotent on p_idempotency_key. See ADR-035 for the carve-out to
--      Part L invariant #8.
--   3. kut.admin_account_events -- shared audit table for both, admin-read RLS
--      like kut.password_reset_events.
--   4. wallet_ledger.reason check widened with 'admin_grant' and 'admin_reset'
--      (a new allowed check value = additive per docs/OPERATIONS.md).
--
-- kut.user_notifications.event_type already allows 'admin_notice' -- no change.
--
-- Tier: additive (ADR-032) -- all `create table` / `create or replace function`
-- / one widened check constraint; nothing existing is rewritten or dropped, and
-- the migration itself mutates no member rows (admin_reset_account does that at
-- run time, gated by is_admin()). Rides the last scheduled backup; no fresh
-- pre-push backup required. SQL-reversible (see below).
--
-- Rollback DDL:
--   drop function kut.admin_reset_account(uuid, uuid);
--   drop function kut.admin_adjust_wallet(uuid, bigint, text);
--   drop table kut.admin_account_events;
--   alter table kut.wallet_ledger drop constraint wallet_ledger_reason_check;
--   alter table kut.wallet_ledger add constraint wallet_ledger_reason_check
--     check (reason in ('starter','attendance_reward','pack_purchase','discard',
--                       'market_sale','market_buy','market_tax','admin_correction'));
--   -- Any 'admin_grant' / 'admin_reset' ledger rows written before rollback
--   -- would need re-mapping first; on hosted this migration is inert until the
--   -- separate VibeTrunk/supabase push, so at rollback time there are none.

-- 1. Widen the ledger reason check -----------------------------------------------
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
    'admin_grant', 'admin_reset'
  ));

-- 2. Shared audit table -------------------------------------------------------
create table kut.admin_account_events (
  id uuid primary key default gen_random_uuid(),
  target_user_id uuid not null references kut.profiles(id) on delete restrict,
  actor_id uuid not null references kut.profiles(id) on delete restrict,
  action text not null check (action in ('wallet_adjust', 'account_reset')),
  amount bigint,
  reason text check (reason is null or char_length(reason) between 1 and 200),
  detail jsonb not null default '{}'::jsonb check (jsonb_typeof(detail) = 'object'),
  created_at timestamptz not null default now()
);

create index admin_account_events_target_idx
  on kut.admin_account_events (target_user_id, created_at desc);

-- Idempotency backstop for admin_reset_account: one committed reset per
-- (target, idempotency key). A racing second call hits this after the first
-- commits and is caught as unique_violation.
create unique index admin_account_events_reset_idem_idx
  on kut.admin_account_events (target_user_id, (detail ->> 'idempotency_key'))
  where action = 'account_reset';

grant select on kut.admin_account_events to authenticated, service_role;
alter table kut.admin_account_events enable row level security;

-- Admin-read only. Rows are written exclusively by the security-definer RPCs
-- below (which bypass RLS); no insert/update/delete policy exists.
create policy "admins read admin account events" on kut.admin_account_events
  for select to authenticated using (kut.is_admin());

-- 3. Coin faucet: admin_adjust_wallet --------------------------------------------
create or replace function kut.admin_adjust_wallet(
  p_user_id uuid,
  p_amount bigint,
  p_reason text
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
  v_reason text := btrim(coalesce(p_reason, ''));
  v_balance bigint;
  v_new_balance bigint;
  v_event_id uuid;
  v_sign text;
begin
  if not kut.is_admin() then
    raise exception 'admin access required' using errcode = '42501';
  end if;
  if p_user_id = auth.uid() then
    raise exception 'you cannot adjust your own wallet' using errcode = 'P0001';
  end if;
  if p_amount is null or p_amount = 0 then
    raise exception 'a non-zero amount is required' using errcode = '22023';
  end if;
  -- Fat-finger guard (ECONOMY.adminWalletAdjustMax, src/game/economy.ts).
  if abs(p_amount) > 100000 then
    raise exception 'amount exceeds the per-adjustment limit of 100000 KUT Coins' using errcode = '22023';
  end if;
  if char_length(v_reason) not between 1 and 200 then
    raise exception 'a reason of 1 to 200 characters is required' using errcode = '22023';
  end if;

  select role into v_caller_role from kut.profiles where id = auth.uid();
  select role, display_name into v_target_role, v_display_name
  from kut.profiles where id = p_user_id;
  if v_target_role is null then
    raise exception 'account not found' using errcode = 'P0002';
  end if;
  if v_target_role = 'superadmin' then
    raise exception 'superadmin wallets cannot be adjusted here' using errcode = 'P0001';
  end if;
  if v_target_role = 'admin' and v_caller_role <> 'superadmin' then
    raise exception 'only a superadmin can adjust an administrator wallet' using errcode = '42501';
  end if;

  insert into kut.wallets (user_id, balance) values (p_user_id, 0)
  on conflict (user_id) do nothing;
  select balance into v_balance from kut.wallets where user_id = p_user_id for update;
  v_balance := coalesce(v_balance, 0);
  v_new_balance := v_balance + p_amount;
  if v_new_balance < 0 then
    raise exception 'adjustment would drop the balance below zero' using errcode = 'P0001';
  end if;

  insert into kut.admin_account_events (target_user_id, actor_id, action, amount, reason, detail)
  values (
    p_user_id, auth.uid(), 'wallet_adjust', p_amount, v_reason,
    jsonb_build_object('balance_before', v_balance, 'balance_after', v_new_balance)
  )
  returning id into v_event_id;

  insert into kut.wallet_ledger (user_id, amount, reason, reference_type, reference_id, idempotency_key)
  values (
    p_user_id, p_amount, 'admin_grant', 'admin_account_event', v_event_id,
    'admin-grant:' || v_event_id::text
  );
  update kut.wallets set balance = v_new_balance, updated_at = now() where user_id = p_user_id;

  v_sign := case when p_amount > 0 then '+' else '' end;
  insert into kut.user_notifications (user_id, event_type, title, body, reference_type, reference_id)
  values (
    p_user_id, 'admin_notice', 'Wallet adjusted',
    format('An admin adjusted your wallet by %s%s KUT Coins. Reason: %s', v_sign, p_amount, v_reason),
    'admin_account_event', v_event_id
  )
  on conflict (user_id, event_type, reference_type, reference_id)
    where reference_type is not null and reference_id is not null do nothing;

  return jsonb_build_object(
    'user_id', p_user_id,
    'display_name', v_display_name,
    'amount', p_amount,
    'balance', v_new_balance,
    'event_id', v_event_id
  );
end;
$$;

revoke execute on function kut.admin_adjust_wallet(uuid, bigint, text) from public, anon;
grant  execute on function kut.admin_adjust_wallet(uuid, bigint, text) to authenticated;

-- 4. Soft account reset: admin_reset_account -----------------------------------
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

  -- Idempotency: a repeat key returns the first result without a second
  -- burn/grant (checked under the profile row lock taken above).
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
  select coalesce(balance, 0) into v_old_balance from kut.wallets where user_id = p_user_id for update;
  v_old_balance := coalesce(v_old_balance, 0);

  -- Cancel the member's active listings first, so the
  -- prevent_burning_listed_card trigger does not block the burn below.
  update kut.market_listings
  set status = 'cancelled', cancelled_at = now()
  where seller_id = p_user_id and status = 'active';

  -- Burn (soft) every owned copy. FK web (pack_opening_cards / market_listings /
  -- market_sales, all ON DELETE RESTRICT) makes a hard delete impossible for
  -- any card ever listed or sold; burn is uniform and keeps history.
  update kut.user_cards set burned_at = now()
  where owner_id = p_user_id and burned_at is null;
  get diagnostics v_burned = row_count;

  -- Wipe pack-opening history (both scoped to this member).
  delete from kut.pack_opening_cards
  where opening_id in (select id from kut.pack_openings where user_id = p_user_id);
  delete from kut.pack_openings where user_id = p_user_id;

  -- Wipe the member's inbox (the admin_notice below is re-added after).
  delete from kut.user_notifications where user_id = p_user_id;

  -- Zero the wallet without deleting ledger rows (immutable, invariant #5 /
  -- ADR-010): one compensating -(balance) entry, then the fresh starter +250.
  if v_old_balance <> 0 then
    insert into kut.wallet_ledger (user_id, amount, reason, reference_type, reference_id, idempotency_key)
    values (
      p_user_id, -v_old_balance, 'admin_reset', 'profile', p_user_id,
      'admin-reset-clear:' || p_idempotency_key::text
    );
  end if;

  -- Re-grant the standard starter inline (do NOT call grant_starter_pack: it
  -- raises P0001 when starter_claimed_at is set, which the reset keeps). Same
  -- "3 eligible Live editions, order by random() limit 3" select it uses.
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

  -- Replay the cosmetic /welcome reveal over the fresh starter cards (ADR-031):
  -- clear starter_opened_at, keep starter_claimed_at.
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
