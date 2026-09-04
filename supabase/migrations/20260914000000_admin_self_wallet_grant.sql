-- ADR-052: a superadmin may grant (or claw back) coins on their own wallet.
--
--   kut.admin_grant_self_wallet(p_amount bigint, p_reason text,
--   p_idempotency_key uuid) -- a second, superadmin-only coin faucet that
--   targets the caller's own wallet (auth.uid()), not an arbitrary p_user_id.
--   kut.admin_adjust_wallet (ADR-035) deliberately refuses to touch the
--   caller's own wallet for every role, including superadmin -- that guard
--   is untouched. This is a separate RPC with its own audit tags
--   ('self_wallet_grant' / 'admin_self_grant') so a self-grant is never
--   indistinguishable from an admin crediting a member in
--   kut.admin_account_events / kut.wallet_ledger. Same guards as
--   admin_adjust_wallet (abs(amount) <= 100000, never below zero, 1-200 char
--   reason required), plus a real idempotency key (admin_adjust_wallet
--   itself lacks one -- this closes that gap for the new RPC rather than
--   repeating it). No admin_notice inbox row is written: a superadmin does
--   not need to be told they granted themselves coins.
--
-- Tier: additive (ADR-032) -- one `create or replace function`, two widened
-- check constraints, one new partial index; nothing existing is rewritten or
-- dropped. Rides the last scheduled backup; no fresh pre-push backup
-- required. SQL-reversible (see below). No 'self_wallet_grant' /
-- 'admin_self_grant' rows exist before this migration.
--
-- Rollback DDL:
--   drop function kut.admin_grant_self_wallet(bigint, text, uuid);
--   drop index kut.admin_account_events_self_grant_idem_idx;
--   alter table kut.admin_account_events drop constraint admin_account_events_action_check;
--   alter table kut.admin_account_events add constraint admin_account_events_action_check
--     check (action in ('wallet_adjust', 'account_reset'));
--   alter table kut.wallet_ledger drop constraint wallet_ledger_reason_check;
--   alter table kut.wallet_ledger add constraint wallet_ledger_reason_check
--     check (reason in ('starter','attendance_reward','pack_purchase','discard',
--                       'market_sale','market_buy','market_tax','admin_correction',
--                       'admin_grant','admin_reset','bibs_bonus','trade_escrow',
--                       'trade_unescrow','trade_sale'));

-- 1. Widen the admin_account_events.action check ---------------------------------
do $$
declare
  v_name text;
begin
  select conname into v_name
  from pg_constraint
  where conrelid = 'kut.admin_account_events'::regclass
    and contype = 'c'
    and pg_get_constraintdef(oid) ilike '%wallet_adjust%'
    and pg_get_constraintdef(oid) ilike '%action%';
  if v_name is null then
    raise exception 'could not locate the admin_account_events.action check constraint';
  end if;
  execute format('alter table kut.admin_account_events drop constraint %I', v_name);
end $$;

alter table kut.admin_account_events
  add constraint admin_account_events_action_check
  check (action in ('wallet_adjust', 'account_reset', 'self_wallet_grant'));

-- 2. Widen the wallet_ledger.reason check -----------------------------------------
do $$
declare
  v_name text;
begin
  select conname into v_name
  from pg_constraint
  where conrelid = 'kut.wallet_ledger'::regclass
    and contype = 'c'
    and pg_get_constraintdef(oid) ilike '%admin_reset%'
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
    'trade_escrow', 'trade_unescrow', 'trade_sale', 'admin_self_grant'
  ));

-- 3. Idempotency backstop for admin_grant_self_wallet: one committed grant per
-- (target, idempotency key). Mirrors admin_account_events_reset_idem_idx.
create unique index admin_account_events_self_grant_idem_idx
  on kut.admin_account_events (target_user_id, (detail ->> 'idempotency_key'))
  where action = 'self_wallet_grant';

-- 4. Self coin faucet: admin_grant_self_wallet ------------------------------------
create or replace function kut.admin_grant_self_wallet(
  p_amount bigint,
  p_reason text,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
declare
  v_caller_role text;
  v_disabled boolean;
  v_display_name text;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_balance bigint;
  v_new_balance bigint;
  v_event_id uuid;
  v_prior record;
begin
  select role, is_disabled, display_name into v_caller_role, v_disabled, v_display_name
  from kut.profiles where id = auth.uid();

  if v_caller_role is distinct from 'superadmin' or coalesce(v_disabled, true) then
    raise exception 'superadmin access required' using errcode = '42501';
  end if;
  if p_idempotency_key is null then
    raise exception 'idempotency key is required' using errcode = '22023';
  end if;
  if p_amount is null or p_amount = 0 then
    raise exception 'a non-zero amount is required' using errcode = '22023';
  end if;
  -- Fat-finger guard (ECONOMY.adminWalletAdjustMax, src/game/economy.ts) --
  -- same cap as kut.admin_adjust_wallet.
  if abs(p_amount) > 100000 then
    raise exception 'amount exceeds the per-adjustment limit of 100000 KUT Coins' using errcode = '22023';
  end if;
  if char_length(v_reason) not between 1 and 200 then
    raise exception 'a reason of 1 to 200 characters is required' using errcode = '22023';
  end if;

  -- Idempotency: a repeat key returns the first result with no second write
  -- (same pattern as kut.admin_reset_account).
  select id, amount, detail into v_prior
  from kut.admin_account_events
  where action = 'self_wallet_grant'
    and target_user_id = auth.uid()
    and detail ->> 'idempotency_key' = p_idempotency_key::text
  limit 1;
  if found then
    return jsonb_build_object(
      'user_id', auth.uid(),
      'display_name', v_display_name,
      'amount', v_prior.amount,
      'balance', (select balance from kut.wallets where user_id = auth.uid()),
      'event_id', v_prior.id,
      'already_processed', true
    );
  end if;

  insert into kut.wallets (user_id, balance) values (auth.uid(), 0)
  on conflict (user_id) do nothing;
  select balance into v_balance from kut.wallets where user_id = auth.uid() for update;
  v_balance := coalesce(v_balance, 0);
  v_new_balance := v_balance + p_amount;
  if v_new_balance < 0 then
    raise exception 'adjustment would drop the balance below zero' using errcode = 'P0001';
  end if;

  insert into kut.admin_account_events (target_user_id, actor_id, action, amount, reason, detail)
  values (
    auth.uid(), auth.uid(), 'self_wallet_grant', p_amount, v_reason,
    jsonb_build_object(
      'balance_before', v_balance, 'balance_after', v_new_balance,
      'idempotency_key', p_idempotency_key::text
    )
  )
  returning id into v_event_id;

  insert into kut.wallet_ledger (user_id, amount, reason, reference_type, reference_id, idempotency_key)
  values (
    auth.uid(), p_amount, 'admin_self_grant', 'admin_account_event', v_event_id,
    'admin-self-grant:' || v_event_id::text
  );
  update kut.wallets set balance = v_new_balance, updated_at = now() where user_id = auth.uid();

  -- No admin_notice: a superadmin does not need to be told they granted
  -- themselves coins.

  return jsonb_build_object(
    'user_id', auth.uid(),
    'display_name', v_display_name,
    'amount', p_amount,
    'balance', v_new_balance,
    'event_id', v_event_id,
    'already_processed', false
  );
end;
$$;

revoke execute on function kut.admin_grant_self_wallet(bigint, text, uuid) from public, anon;
grant  execute on function kut.admin_grant_self_wallet(bigint, text, uuid) to authenticated;
