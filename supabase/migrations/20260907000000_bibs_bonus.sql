-- Batch E2 (tester feedback #5), ADR-037: a coin bonus for washing the bibs.
--
-- The member who washed the bibs after a session gets a one-off
-- ECONOMY.bibsCoinBonus (100 KUT Coins) -- meaningful, well under a session's
-- 250 attendance reward. Coins ONLY: no rating / OVR effect (that would add a
-- new input to _rebuild_season_core, the fixtures, and Part L -- punted).
--
-- Storage: one washer per session -> a nullable column
-- kut.match_sessions.bibs_washed_by, not a table. Validated null-or-(a distinct
-- attendee of that session) inside the publish / correct RPCs (a CHECK cannot
-- reference other tables).
--
-- Reward path mirrors kut.grant_attendance_rewards exactly:
--   * kut.bibs_rewards guard table, PK (session_id, player_id) -- same shape as
--     kut.attendance_rewards (incl. the deferrable ledger_id FK).
--   * kut.grant_bibs_reward(p_session_id) -- security definer, called from
--     kut.process_published_session_rewards next to grant_attendance_rewards, so
--     it fires on publish and on any attendance churn during a correction.
--   * wallet_ledger.reason gains 'bibs_bonus'; the ledger idempotency key is
--     'bibs:' || session || ':' || washer -- at most once per (session, washer),
--     never re-paid for the same washer on a correction. A *changed* washer on a
--     correction re-fires (a fresh guard row); the previous washer keeps the
--     coins (forward-only, invariant #9-style -- Part L §162).
--   * user_notifications.event_type gains 'bibs_bonus' (a distinct type so the
--     (user, event_type, ref_type, ref_id) unique key does not collide with the
--     washer's own attendance_reward row for the same session).
--
-- Signatures change: kut.publish_attendance_session and
-- kut.correct_published_attendance_session each gain a trailing
-- `p_bibs_washed_by uuid default null`. The old signatures are dropped and
-- recreated (a `create or replace` cannot change the argument list); existing
-- 4-/5-arg callers are unaffected by the new defaulted parameter.
--
-- Tier: additive (ADR-032). New column (nullable), new table, two widened check
-- constraints, `create or replace` / drop+recreate of functions; no member row
-- is rewritten and the migration itself grants no coins (grant_bibs_reward does
-- that at run time, only for sessions that name a washer). Rides the last
-- scheduled backup; no fresh pre-push backup.
--
-- Rollback DDL:
--   drop function kut.grant_bibs_reward(uuid);
--   drop function kut.publish_attendance_session(uuid, date, text, jsonb, uuid);
--   drop function kut.correct_published_attendance_session(uuid, date, text, jsonb, text, uuid);
--   -- then `create or replace` the prior 4-/5-arg versions from 20260816030000
--   -- and 20260816060300, and process_published_session_rewards from 20260816070000.
--   drop table kut.bibs_rewards;
--   alter table kut.match_sessions drop column bibs_washed_by;
--   alter table kut.wallet_ledger drop constraint wallet_ledger_reason_check;
--   alter table kut.wallet_ledger add constraint wallet_ledger_reason_check
--     check (reason in ('starter','attendance_reward','pack_purchase','discard',
--       'market_sale','market_buy','market_tax','admin_correction','admin_grant','admin_reset'));
--   alter table kut.user_notifications drop constraint user_notifications_event_type_check;
--   alter table kut.user_notifications add constraint user_notifications_event_type_check
--     check (event_type in ('market_sale','market_purchase','attendance_reward','pack_opened','admin_notice'));
--   -- (safe only while no 'bibs_bonus' ledger/notification rows exist; on hosted
--   -- this migration is inert until the separate VibeTrunk/supabase push.)

-- 1. Storage column ----------------------------------------------------------
alter table kut.match_sessions
  add column bibs_washed_by uuid references kut.players(id) on delete restrict;

comment on column kut.match_sessions.bibs_washed_by is
  'Player who washed the bibs after this session (ADR-037). NULL = nobody. '
  'Validated as a distinct attendee inside publish_/correct_ RPCs.';

-- 2. Guard table (mirrors kut.attendance_rewards) --------------------------------
create table kut.bibs_rewards (
  session_id uuid not null references kut.match_sessions(id) on delete restrict,
  player_id uuid not null references kut.players(id) on delete restrict,
  user_id uuid not null references kut.profiles(id) on delete restrict,
  ledger_id uuid not null references kut.wallet_ledger(id) on delete restrict deferrable initially deferred,
  created_at timestamptz not null default now(),
  primary key (session_id, player_id)
);

create index bibs_rewards_user_idx on kut.bibs_rewards (user_id, created_at desc);

grant select on kut.bibs_rewards to authenticated, service_role;
alter table kut.bibs_rewards enable row level security;

create policy "users read own bibs rewards" on kut.bibs_rewards
  for select to authenticated using (user_id = auth.uid());
create policy "admins read bibs rewards" on kut.bibs_rewards
  for select to authenticated using (kut.is_admin());

-- 3. Widen wallet_ledger.reason with 'bibs_bonus' -----------------------------
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
    'admin_grant', 'admin_reset', 'bibs_bonus'
  ));

-- 4. Widen user_notifications.event_type with 'bibs_bonus' --------------------
do $$
declare
  v_name text;
begin
  select conname into v_name
  from pg_constraint
  where conrelid = 'kut.user_notifications'::regclass
    and contype = 'c'
    and pg_get_constraintdef(oid) ilike '%event_type%'
    and pg_get_constraintdef(oid) ilike '%market_sale%';
  if v_name is null then
    raise exception 'could not locate the user_notifications.event_type check constraint';
  end if;
  execute format('alter table kut.user_notifications drop constraint %I', v_name);
end $$;

alter table kut.user_notifications
  add constraint user_notifications_event_type_check
  check (event_type in (
    'market_sale', 'market_purchase', 'attendance_reward', 'pack_opened',
    'admin_notice', 'bibs_bonus'
  ));

-- 5. grant_bibs_reward -- one 100-coin payout for the session's bibs washer -----
-- Modelled on kut.grant_attendance_rewards (20260831000000). Idempotent on the
-- kut.bibs_rewards PK (session_id, player_id) plus the unique ledger key.
-- Returns 0 (no error) when the session names no washer, or the washer has no
-- active linked account, or the reward was already granted.
create or replace function kut.grant_bibs_reward(p_session_id uuid)
returns integer
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
declare
  v_washer_player_id uuid;
  v_session_date date;
  v_user_id uuid;
  v_ledger_id uuid := gen_random_uuid();
  -- Canonical amount: BUILD_SPEC.md Part 145 (BIBS_COIN_BONUS). Mirrored by
  -- ECONOMY.bibsCoinBonus in src/game/economy.ts. See ADR-037.
  v_amount constant bigint := 100;
begin
  select bibs_washed_by, session_date
  into v_washer_player_id, v_session_date
  from kut.match_sessions
  where id = p_session_id and status = 'published';

  if v_washer_player_id is null then
    return 0;
  end if;

  select id into v_user_id
  from kut.profiles
  where player_id = v_washer_player_id and not is_disabled;

  if v_user_id is null then
    return 0;
  end if;

  insert into kut.bibs_rewards (session_id, player_id, user_id, ledger_id)
  values (p_session_id, v_washer_player_id, v_user_id, v_ledger_id)
  on conflict (session_id, player_id) do nothing;

  if not found then
    return 0;
  end if;

  insert into kut.wallets (user_id, balance) values (v_user_id, 0)
  on conflict (user_id) do nothing;
  insert into kut.wallet_ledger (id, user_id, amount, reason, reference_type, reference_id, idempotency_key)
  values (
    v_ledger_id, v_user_id, v_amount, 'bibs_bonus', 'match_session', p_session_id,
    'bibs:' || p_session_id::text || ':' || v_washer_player_id::text
  );
  update kut.wallets set balance = balance + v_amount, updated_at = now() where user_id = v_user_id;

  insert into kut.user_notifications (user_id, event_type, title, body, reference_type, reference_id)
  values (
    v_user_id, 'bibs_bonus', 'Bibs bonus',
    format('You received %s KUT Coins for washing the bibs after the session on %s.',
           v_amount, to_char(v_session_date, 'DD Mon YYYY')),
    'match_session', p_session_id
  )
  on conflict (user_id, event_type, reference_type, reference_id)
    where reference_type is not null and reference_id is not null do nothing;

  return 1;
end;
$$;

revoke execute on function kut.grant_bibs_reward(uuid) from public, anon, authenticated;

-- 6. process_published_session_rewards -- also grant the bibs bonus ------------
-- Byte-identical to 20260816070000_wallet_starter_and_attendance_rewards.sql
-- except the added `perform kut.grant_bibs_reward(v_session_id);` line.
create or replace function kut.process_published_session_rewards()
returns trigger
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
declare
  v_session_id uuid;
begin
  if tg_table_name = 'attendance' then
    v_session_id := coalesce(new.session_id, old.session_id);
  else
    v_session_id := coalesce(new.id, old.id);
  end if;
  perform kut.grant_attendance_rewards(v_session_id);
  perform kut.grant_bibs_reward(v_session_id);
  return coalesce(new, old);
end;
$$;

revoke execute on function kut.process_published_session_rewards() from public, anon, authenticated;

-- 7. publish_attendance_session -- gains p_bibs_washed_by ----------------------
-- Byte-identical to 20260816030000_publish_attendance_session.sql except: the
-- trailing p_bibs_washed_by parameter, a "washer must be an attendee" check, and
-- storing it on the session before publish (so the reward trigger sees it).
drop function kut.publish_attendance_session(uuid, date, text, jsonb);

create function kut.publish_attendance_session(
  p_season_id uuid,
  p_session_date date,
  p_session_type text,
  p_attendance jsonb,
  p_bibs_washed_by uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
declare
  v_session_id uuid;
  v_attendee_count integer;
  v_known_player_count integer;
begin
  if not kut.is_admin() then
    raise exception 'admin access required' using errcode = '42501';
  end if;

  if p_session_type not in ('monday', 'friday', 'other') then
    raise exception 'invalid session type' using errcode = '22023';
  end if;

  if jsonb_typeof(p_attendance) <> 'array' or jsonb_array_length(p_attendance) = 0 then
    raise exception 'attendance must contain at least one player' using errcode = '22023';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_attendance) as item
    where jsonb_typeof(item -> 'player_id') <> 'string'
      or jsonb_typeof(item -> 'goals') <> 'number'
      or not ((item ->> 'goals') ~ '^[0-9]+$')
  ) then
    raise exception 'attendance contains an invalid player or goal total' using errcode = '22023';
  end if;

  select count(*), count(distinct (item ->> 'player_id')::uuid)
  into v_attendee_count, v_known_player_count
  from jsonb_array_elements(p_attendance) as item;

  if v_attendee_count <> v_known_player_count then
    raise exception 'each player can attend only once' using errcode = '22023';
  end if;

  select count(*) into v_known_player_count
  from kut.players p
  join jsonb_array_elements(p_attendance) as item
    on p.id = (item ->> 'player_id')::uuid
  where p.is_active;

  if v_known_player_count <> v_attendee_count then
    raise exception 'attendance contains an unknown or inactive player' using errcode = '22023';
  end if;

  if p_bibs_washed_by is not null and not exists (
    select 1 from jsonb_array_elements(p_attendance) as item
    where (item ->> 'player_id')::uuid = p_bibs_washed_by
  ) then
    raise exception 'the bibs washer must be one of the session attendees' using errcode = '22023';
  end if;

  insert into kut.match_sessions (
    season_id,
    session_date,
    session_type,
    status,
    created_by,
    bibs_washed_by
  ) values (
    p_season_id,
    p_session_date,
    p_session_type,
    'draft',
    auth.uid(),
    p_bibs_washed_by
  ) returning id into v_session_id;

  insert into kut.attendance (session_id, player_id, goals)
  select
    v_session_id,
    (item ->> 'player_id')::uuid,
    (item ->> 'goals')::integer
  from jsonb_array_elements(p_attendance) as item;

  perform kut.publish_session(v_session_id);

  return v_session_id;
end;
$$;

revoke execute on function kut.publish_attendance_session(uuid, date, text, jsonb, uuid) from public, anon;
grant execute on function kut.publish_attendance_session(uuid, date, text, jsonb, uuid) to authenticated, service_role;

-- 8. correct_published_attendance_session -- gains p_bibs_washed_by ------------
-- Byte-identical to 20260816060300_reversible_session_lifecycle.sql except: the
-- trailing p_bibs_washed_by parameter, a "washer must be an attendee" check
-- against the corrected attendance, and storing the washer BEFORE the
-- attendance is replaced (so the reward trigger re-fires for a changed washer).
drop function kut.correct_published_attendance_session(uuid, date, text, jsonb, text);

create function kut.correct_published_attendance_session(
  p_session_id uuid,
  p_session_date date,
  p_session_type text,
  p_attendance jsonb,
  p_reason text,
  p_bibs_washed_by uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
declare
  v_season_id uuid;
  v_status text;
  v_previous_session_date date;
  v_previous_session_type text;
  v_previous_attendance jsonb;
  v_attendee_count integer;
  v_known_player_count integer;
begin
  if not kut.is_admin() then
    raise exception 'admin access required' using errcode = '42501';
  end if;

  if p_session_type not in ('monday', 'friday', 'other') then
    raise exception 'invalid session type' using errcode = '22023';
  end if;

  if jsonb_typeof(p_attendance) <> 'array' or jsonb_array_length(p_attendance) = 0 then
    raise exception 'attendance must contain at least one player' using errcode = '22023';
  end if;

  if char_length(trim(coalesce(p_reason, ''))) not between 3 and 500 then
    raise exception 'a correction reason is required' using errcode = '22023';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_attendance) as item
    where jsonb_typeof(item -> 'player_id') <> 'string'
      or (item ->> 'player_id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
      or jsonb_typeof(item -> 'goals') <> 'number'
      or not ((item ->> 'goals') ~ '^[0-9]+$')
  ) then
    raise exception 'attendance contains an invalid player or goal total' using errcode = '22023';
  end if;

  select season_id, status, session_date, session_type
  into v_season_id, v_status, v_previous_session_date, v_previous_session_type
  from kut.match_sessions
  where id = p_session_id and status in ('published', 'cancelled')
  for update;

  if v_season_id is null then
    raise exception 'published or cancelled session not found' using errcode = 'P0002';
  end if;

  select count(*), count(distinct (item ->> 'player_id')::uuid)
  into v_attendee_count, v_known_player_count
  from jsonb_array_elements(p_attendance) as item;

  if v_attendee_count <> v_known_player_count then
    raise exception 'each player can attend only once' using errcode = '22023';
  end if;

  select coalesce(
    jsonb_agg(jsonb_build_object('player_id', player_id, 'goals', goals) order by player_id),
    '[]'::jsonb
  ) into v_previous_attendance
  from kut.attendance
  where session_id = p_session_id;

  select count(*) into v_known_player_count
  from kut.players p
  join jsonb_array_elements(p_attendance) as item
    on p.id = (item ->> 'player_id')::uuid
  where p.is_active
    or exists (
      select 1 from kut.attendance a
      where a.session_id = p_session_id and a.player_id = p.id
    );

  if v_known_player_count <> v_attendee_count then
    raise exception 'attendance contains an unknown or inactive player' using errcode = '22023';
  end if;

  if p_bibs_washed_by is not null and not exists (
    select 1 from jsonb_array_elements(p_attendance) as item
    where (item ->> 'player_id')::uuid = p_bibs_washed_by
  ) then
    raise exception 'the bibs washer must be one of the session attendees' using errcode = '22023';
  end if;

  insert into kut.session_corrections (
    session_id, previous_session_date, previous_session_type, previous_attendance,
    corrected_session_date, corrected_session_type, corrected_attendance, reason, corrected_by
  ) values (
    p_session_id, v_previous_session_date, v_previous_session_type, v_previous_attendance,
    p_session_date, p_session_type, p_attendance, trim(p_reason), auth.uid()
  );

  -- Store the washer before the attendance churn below so the reward trigger
  -- (fired by the delete/insert) sees the corrected washer (ADR-037).
  update kut.match_sessions set bibs_washed_by = p_bibs_washed_by where id = p_session_id;

  delete from kut.attendance where session_id = p_session_id;
  insert into kut.attendance (session_id, player_id, goals)
  select p_session_id, (item ->> 'player_id')::uuid, (item ->> 'goals')::integer
  from jsonb_array_elements(p_attendance) as item;

  update kut.match_sessions
  set session_date = p_session_date,
      session_type = p_session_type
  where id = p_session_id;

  if v_status = 'published' then
    perform kut.rebuild_season(v_season_id);
  end if;

  return p_session_id;
end;
$$;

revoke execute on function kut.correct_published_attendance_session(uuid, date, text, jsonb, text, uuid) from public, anon;
grant execute on function kut.correct_published_attendance_session(uuid, date, text, jsonb, text, uuid) to authenticated, service_role;
