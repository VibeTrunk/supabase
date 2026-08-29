-- Three changes:
--   1. kut.profiles.username -- a self-chosen login handle. Sign-up now asks
--      for a username instead of an email; the app maps it to a synthetic
--      address for Supabase Auth (see src/lib/auth/username.ts). The public
--      display name stays the linked player's real name.
--   2. kut.admin_set_profile_player(uuid, uuid) -- an admin links / unlinks an
--      account to a player card from the admin UI. Forward-only: linking does
--      NOT back-pay attendance rewards for the player's past sessions.
--   3. kut.grant_attendance_rewards now writes a dated "attendance reward"
--      message into the member's inbox alongside the coins, and existing
--      attendance rewards are backfilled with one message each. The reward
--      amount is also raised from 75 to 250 (ADR-029); this is NOT applied
--      retroactively -- past rewards keep the amount they were credited, and
--      backfilled messages report that historical amount via ledger.amount.
--
-- See ADR-028 and ADR-029.
--
-- Rollback:
--   drop function kut.admin_set_profile_player(uuid, uuid);
--   -- restore kut.grant_attendance_rewards / kut.claim_invitation to their
--   -- pre-change bodies (below), then:
--   alter table kut.profiles drop column username;
--   delete from kut.user_notifications where event_type = 'attendance_reward';
--
-- Pre-change kut.claim_invitation was kut.claim_invitation(text, uuid) with the
-- same body minus the username validation and the username insert column.
-- Pre-change kut.grant_attendance_rewards used a hard-coded 75 (v_amount) and
-- wrote no notification.

-- 1. Username -----------------------------------------------------------------
alter table kut.profiles
  add column username text unique
  check (username is null or username ~ '^[a-z0-9_]{3,30}$');

-- 2. claim_invitation gains a username -------------------------------------
drop function if exists kut.claim_invitation(text, uuid);

create function kut.claim_invitation(
  p_token_hash text,
  p_user_id uuid,
  p_username text
)
returns uuid
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
declare
  v_player_id uuid;
  v_display_name text;
  v_username text := lower(btrim(coalesce(p_username, '')));
begin
  if p_token_hash !~ '^[a-f0-9]{64}$' then
    raise exception 'invite is invalid or expired' using errcode = '22023';
  end if;

  if v_username !~ '^[a-z0-9_]{3,30}$' then
    raise exception 'invalid username' using errcode = '22023';
  end if;

  select invitation.player_id, player.display_name
  into v_player_id, v_display_name
  from kut.invitations invitation
  join kut.players player on player.id = invitation.player_id
  where invitation.token_hash = p_token_hash
    and invitation.consumed_at is null
    and invitation.expires_at > now()
    and player.is_active
  for update of invitation;

  if v_player_id is null then
    raise exception 'invite is invalid or expired' using errcode = '22023';
  end if;

  insert into kut.profiles (id, display_name, role, player_id, username)
  values (p_user_id, v_display_name, 'user', v_player_id, v_username);

  perform kut.grant_starter_pack(p_user_id);

  update kut.invitations
  set consumed_at = now(), consumed_by = p_user_id
  where token_hash = p_token_hash;

  return v_player_id;
end;
$$;

revoke execute on function kut.claim_invitation(text, uuid, text) from public, anon, authenticated;
grant execute on function kut.claim_invitation(text, uuid, text) to service_role;

-- 3. Admin links an account to a player -----------------------------------
create or replace function kut.admin_set_profile_player(p_user_id uuid, p_player_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
declare
  v_existing uuid;
  v_player_name text;
begin
  if not kut.is_admin() then
    raise exception 'admin access required' using errcode = '42501';
  end if;

  perform 1 from kut.profiles where id = p_user_id;
  if not found then
    raise exception 'account not found' using errcode = 'P0002';
  end if;

  if p_player_id is not null then
    select display_name into v_player_name from kut.players where id = p_player_id;
    if not found then
      raise exception 'player not found' using errcode = 'P0002';
    end if;

    select id into v_existing
    from kut.profiles
    where player_id = p_player_id and id <> p_user_id;
    if v_existing is not null then
      raise exception 'that player is already linked to another account' using errcode = 'P0001';
    end if;
  end if;

  update kut.profiles set player_id = p_player_id, updated_at = now() where id = p_user_id;
  insert into kut.wallets (user_id, balance) values (p_user_id, 0) on conflict (user_id) do nothing;

  -- Forward-only: no attendance-reward back-pay for the player's past sessions.
  return jsonb_build_object('user_id', p_user_id, 'player_id', p_player_id, 'player_name', v_player_name);
end;
$$;

revoke execute on function kut.admin_set_profile_player(uuid, uuid) from public, anon;
grant  execute on function kut.admin_set_profile_player(uuid, uuid) to authenticated;

-- 4. Attendance rewards write an inbox message ---------------------------
create or replace function kut.grant_attendance_rewards(p_session_id uuid)
returns integer
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
declare
  v_reward record;
  v_ledger_id uuid;
  v_awarded_count integer := 0;
  v_session_date date;
  -- Canonical amount: BUILD_SPEC.md Part 145 (ATTENDANCE_COIN_REWARD). Mirrored
  -- by ECONOMY.attendanceCoinReward in src/game/economy.ts. See ADR-029.
  v_amount constant bigint := 250;
begin
  select session_date into v_session_date from kut.match_sessions where id = p_session_id;

  for v_reward in
    select attendance.player_id, profile.id as user_id
    from kut.attendance attendance
    join kut.match_sessions session on session.id = attendance.session_id
    join kut.profiles profile on profile.player_id = attendance.player_id
    where attendance.session_id = p_session_id
      and session.status = 'published'
      and not profile.is_disabled
  loop
    v_ledger_id := gen_random_uuid();
    insert into kut.attendance_rewards (session_id, player_id, user_id, ledger_id)
    values (p_session_id, v_reward.player_id, v_reward.user_id, v_ledger_id)
    on conflict (session_id, player_id) do nothing;

    if found then
      insert into kut.wallets (user_id, balance) values (v_reward.user_id, 0)
      on conflict (user_id) do nothing;
      insert into kut.wallet_ledger (id, user_id, amount, reason, reference_type, reference_id, idempotency_key)
      values (
        v_ledger_id, v_reward.user_id, v_amount, 'attendance_reward', 'match_session', p_session_id,
        'attendance:' || p_session_id::text || ':' || v_reward.player_id::text
      );
      update kut.wallets set balance = balance + v_amount, updated_at = now() where user_id = v_reward.user_id;

      insert into kut.user_notifications (user_id, event_type, title, body, reference_type, reference_id)
      values (
        v_reward.user_id, 'attendance_reward', 'Attendance reward',
        format('You received %s KUT Coins for attending the session on %s.',
               v_amount, to_char(v_session_date, 'DD Mon YYYY')),
        'match_session', p_session_id
      )
      on conflict (user_id, event_type, reference_type, reference_id)
        where reference_type is not null and reference_id is not null do nothing;

      v_awarded_count := v_awarded_count + 1;
    end if;
  end loop;
  return v_awarded_count;
end;
$$;

revoke execute on function kut.grant_attendance_rewards(uuid) from public, anon, authenticated;

-- Backfill one message per already-granted attendance reward, using the amount
-- that was actually credited.
insert into kut.user_notifications (user_id, event_type, title, body, reference_type, reference_id, created_at)
select
  ar.user_id, 'attendance_reward', 'Attendance reward',
  format('You received %s KUT Coins for attending the session on %s.',
         ledger.amount, to_char(session.session_date, 'DD Mon YYYY')),
  'match_session', ar.session_id, ar.created_at
from kut.attendance_rewards ar
join kut.match_sessions session on session.id = ar.session_id
join kut.wallet_ledger ledger on ledger.id = ar.ledger_id
on conflict (user_id, event_type, reference_type, reference_id)
  where reference_type is not null and reference_id is not null do nothing;
