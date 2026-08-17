create table kut.card_editions (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references kut.players(id) on delete restrict,
  edition_type text not null check (edition_type in ('live', 'totw', 'hat_trick', 'milestone', 'iron_man', 'comeback', 'tots', 'other')),
  title text not null check (char_length(title) between 1 and 120),
  is_live boolean not null default false,
  snapshot_ovr integer check (snapshot_ovr between 1 and 99),
  snapshot_pac integer check (snapshot_pac between 1 and 99),
  snapshot_sho integer check (snapshot_sho between 1 and 99),
  snapshot_pas integer check (snapshot_pas between 1 and 99),
  snapshot_dri integer check (snapshot_dri between 1 and 99),
  snapshot_def integer check (snapshot_def between 1 and 99),
  snapshot_phy integer check (snapshot_phy between 1 and 99),
  special_discard_multiplier numeric(6, 3) check (special_discard_multiplier > 0),
  pack_available_from timestamptz,
  pack_available_until timestamptz,
  max_supply integer check (max_supply > 0),
  minted_count integer not null default 0 check (minted_count >= 0),
  pack_weight numeric(12, 4) check (pack_weight > 0),
  issued_at timestamptz,
  metadata jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata) = 'object'),
  created_at timestamptz not null default now(),
  check (
    (is_live and edition_type = 'live'
      and snapshot_ovr is null and snapshot_pac is null and snapshot_sho is null
      and snapshot_pas is null and snapshot_dri is null and snapshot_def is null and snapshot_phy is null)
    or
    (not is_live and edition_type <> 'live')
  )
);

create unique index card_editions_one_live_per_player_idx
  on kut.card_editions (player_id) where is_live;

insert into kut.card_editions (player_id, edition_type, title, is_live)
select id, 'live', display_name || ' Live', true
from kut.players
on conflict do nothing;

create table kut.user_cards (
  id uuid primary key default gen_random_uuid(),
  edition_id uuid not null references kut.card_editions(id) on delete restrict,
  owner_id uuid not null references kut.profiles(id) on delete cascade,
  is_tradeable boolean not null default true,
  source text not null check (source in ('starter', 'pack', 'attendance_reward', 'special_grant', 'challenge', 'admin')),
  acquired_at timestamptz not null default now(),
  burned_at timestamptz,
  created_at timestamptz not null default now()
);

create index user_cards_owner_active_idx on kut.user_cards (owner_id) where burned_at is null;
create index user_cards_edition_idx on kut.user_cards (edition_id);

create table kut.wallets (
  user_id uuid primary key references kut.profiles(id) on delete cascade,
  balance bigint not null default 0 check (balance >= 0),
  updated_at timestamptz not null default now()
);

insert into kut.wallets (user_id)
select id from kut.profiles
on conflict (user_id) do nothing;

create table kut.wallet_ledger (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references kut.profiles(id) on delete cascade,
  amount bigint not null check (amount <> 0),
  reason text not null check (reason in ('starter', 'attendance_reward', 'pack_purchase', 'discard', 'market_sale', 'market_buy', 'market_tax', 'admin_correction')),
  reference_type text,
  reference_id uuid,
  idempotency_key text,
  created_at timestamptz not null default now()
);

create unique index wallet_ledger_user_idempotency_idx
  on kut.wallet_ledger (user_id, idempotency_key)
  where idempotency_key is not null;
create index wallet_ledger_user_created_idx on kut.wallet_ledger (user_id, created_at desc);

create table kut.attendance_rewards (
  session_id uuid not null references kut.match_sessions(id) on delete restrict,
  player_id uuid not null references kut.players(id) on delete restrict,
  user_id uuid not null references kut.profiles(id) on delete restrict,
  ledger_id uuid not null references kut.wallet_ledger(id) on delete restrict deferrable initially deferred,
  created_at timestamptz not null default now(),
  primary key (session_id, player_id)
);

create index attendance_rewards_user_idx on kut.attendance_rewards (user_id, created_at desc);

grant select on kut.card_editions, kut.user_cards, kut.wallets, kut.wallet_ledger, kut.attendance_rewards to authenticated, service_role;

alter table kut.card_editions enable row level security;
alter table kut.user_cards enable row level security;
alter table kut.wallets enable row level security;
alter table kut.wallet_ledger enable row level security;
alter table kut.attendance_rewards enable row level security;

create policy "authenticated users read card editions" on kut.card_editions
  for select to authenticated using (true);
create policy "admins manage card editions" on kut.card_editions
  for all to authenticated using (kut.is_admin()) with check (kut.is_admin());

create policy "users read own cards" on kut.user_cards
  for select to authenticated using (owner_id = auth.uid());
create policy "admins read all cards" on kut.user_cards
  for select to authenticated using (kut.is_admin());

create policy "users read own wallet" on kut.wallets
  for select to authenticated using (user_id = auth.uid());
create policy "admins read wallets" on kut.wallets
  for select to authenticated using (kut.is_admin());

create policy "users read own ledger" on kut.wallet_ledger
  for select to authenticated using (user_id = auth.uid());
create policy "admins read ledger" on kut.wallet_ledger
  for select to authenticated using (kut.is_admin());

create policy "users read own attendance rewards" on kut.attendance_rewards
  for select to authenticated using (user_id = auth.uid());
create policy "admins read attendance rewards" on kut.attendance_rewards
  for select to authenticated using (kut.is_admin());

create or replace function kut.grant_starter_pack(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
declare
  v_edition_ids uuid[];
begin
  perform 1 from kut.profiles where id = p_user_id and not is_disabled for update;
  if not found then
    raise exception 'active profile not found' using errcode = 'P0002';
  end if;

  if exists (select 1 from kut.profiles where id = p_user_id and starter_claimed_at is not null) then
    raise exception 'starter pack already claimed' using errcode = 'P0001';
  end if;

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

  update kut.profiles set starter_claimed_at = now() where id = p_user_id;
  insert into kut.wallets (user_id, balance) values (p_user_id, 0)
  on conflict (user_id) do nothing;
  update kut.wallets set balance = balance + 250, updated_at = now() where user_id = p_user_id;
  insert into kut.wallet_ledger (user_id, amount, reason, reference_type, reference_id, idempotency_key)
  values (p_user_id, 250, 'starter', 'profile', p_user_id, 'starter:' || p_user_id::text);
  insert into kut.user_cards (edition_id, owner_id, is_tradeable, source)
  select edition_id, p_user_id, false, 'starter'
  from unnest(v_edition_ids) as edition_id;

  return jsonb_build_object('coins', 250, 'edition_ids', to_jsonb(v_edition_ids));
end;
$$;

create or replace function kut.claim_starter_pack()
returns jsonb
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  return kut.grant_starter_pack(auth.uid());
end;
$$;

revoke execute on function kut.grant_starter_pack(uuid) from public, anon, authenticated;
revoke execute on function kut.claim_starter_pack() from public, anon;
grant execute on function kut.claim_starter_pack() to authenticated, service_role;

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
begin
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
        v_ledger_id, v_reward.user_id, 75, 'attendance_reward', 'match_session', p_session_id,
        'attendance:' || p_session_id::text || ':' || v_reward.player_id::text
      );
      update kut.wallets set balance = balance + 75, updated_at = now() where user_id = v_reward.user_id;
      v_awarded_count := v_awarded_count + 1;
    end if;
  end loop;
  return v_awarded_count;
end;
$$;

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
  return coalesce(new, old);
end;
$$;

create trigger match_sessions_grant_attendance_rewards
  after update of status on kut.match_sessions
  for each row
  when (new.status = 'published' and old.status is distinct from 'published')
  execute function kut.process_published_session_rewards();

create trigger attendance_grant_attendance_rewards
  after insert or update or delete on kut.attendance
  for each row
  execute function kut.process_published_session_rewards();

revoke execute on function kut.grant_attendance_rewards(uuid) from public, anon, authenticated;
revoke execute on function kut.process_published_session_rewards() from public, anon, authenticated;

do $$
declare
  v_session record;
begin
  for v_session in select id from kut.match_sessions where status = 'published' loop
    perform kut.grant_attendance_rewards(v_session.id);
  end loop;
end;
$$;

create or replace function kut.claim_invitation(
  p_token_hash text,
  p_user_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
declare
  v_player_id uuid;
  v_display_name text;
begin
  if p_token_hash !~ '^[a-f0-9]{64}$' then
    raise exception 'invite is invalid or expired' using errcode = '22023';
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

  insert into kut.profiles (id, display_name, role, player_id)
  values (p_user_id, v_display_name, 'user', v_player_id);

  perform kut.grant_starter_pack(p_user_id);

  update kut.invitations
  set consumed_at = now(), consumed_by = p_user_id
  where token_hash = p_token_hash;

  return v_player_id;
end;
$$;
