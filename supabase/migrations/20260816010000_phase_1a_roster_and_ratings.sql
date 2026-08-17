create table kut.players (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique check (slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'),
  display_name text not null check (char_length(display_name) between 1 and 80),
  full_name text,
  photo_path text,
  archetype text not null default 'all_rounder'
    check (archetype in ('all_rounder', 'speedster', 'finisher', 'playmaker', 'defender', 'tank')),
  is_active boolean not null default true,
  is_collectible boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table kut.seasons (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 80),
  starts_on date not null,
  ends_on date,
  is_active boolean not null default false,
  created_at timestamptz not null default now(),
  check (ends_on is null or ends_on >= starts_on)
);

create unique index seasons_one_active_idx on kut.seasons (is_active) where is_active;

create table kut.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null check (char_length(display_name) between 1 and 80),
  club_name text check (char_length(club_name) <= 80),
  role text not null default 'user' check (role in ('user', 'admin', 'superadmin')),
  player_id uuid unique references kut.players(id) on delete set null,
  is_disabled boolean not null default false,
  starter_claimed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table kut.match_sessions (
  id uuid primary key default gen_random_uuid(),
  season_id uuid not null references kut.seasons(id) on delete restrict,
  session_date date not null,
  session_type text not null check (session_type in ('monday', 'friday', 'other')),
  status text not null default 'draft' check (status in ('draft', 'published', 'cancelled')),
  location text,
  notes text,
  created_by uuid references kut.profiles(id) on delete set null,
  published_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (season_id, session_date, session_type),
  check ((status = 'published') = (published_at is not null))
);

create table kut.attendance (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references kut.match_sessions(id) on delete cascade,
  player_id uuid not null references kut.players(id) on delete restrict,
  goals integer not null default 0 check (goals >= 0),
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (session_id, player_id)
);

create table kut.player_season_state (
  player_id uuid not null references kut.players(id) on delete cascade,
  season_id uuid not null references kut.seasons(id) on delete cascade,
  activity_score numeric(7, 4) not null check (activity_score between 0 and 100),
  form_score numeric(7, 4) not null check (form_score between 0 and 8),
  live_ovr integer not null check (live_ovr between 30 and 83),
  pac integer not null check (pac between 1 and 99),
  sho integer not null check (sho between 1 and 99),
  pas integer not null check (pas between 1 and 99),
  dri integer not null check (dri between 1 and 99),
  def integer not null check (def between 1 and 99),
  phy integer not null check (phy between 1 and 99),
  rarity_tier text not null check (rarity_tier in ('common', 'bronze', 'silver', 'gold', 'holo', 'elite')),
  last_week_start date,
  last_rebuilt_at timestamptz not null default now(),
  primary key (player_id, season_id)
);

create index attendance_session_idx on kut.attendance (session_id);
create index attendance_player_idx on kut.attendance (player_id);
create index match_sessions_season_date_idx on kut.match_sessions (season_id, session_date);

create or replace function kut.set_updated_at()
returns trigger
language plpgsql
set search_path = kut, public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger players_set_updated_at before update on kut.players
  for each row execute function kut.set_updated_at();
create trigger profiles_set_updated_at before update on kut.profiles
  for each row execute function kut.set_updated_at();
create trigger match_sessions_set_updated_at before update on kut.match_sessions
  for each row execute function kut.set_updated_at();
create trigger attendance_set_updated_at before update on kut.attendance
  for each row execute function kut.set_updated_at();

create or replace function kut.is_admin()
returns boolean
language sql
stable
security definer
set search_path = kut, auth, public
as $$
  select exists (
    select 1
    from kut.profiles
    where id = auth.uid()
      and role in ('admin', 'superadmin')
      and is_disabled = false
  );
$$;

grant usage on schema kut to authenticated, service_role;
grant select, insert, update, delete on all tables in schema kut to authenticated, service_role;
grant usage, select on all sequences in schema kut to authenticated, service_role;
grant execute on all functions in schema kut to authenticated, service_role;

alter table kut.players enable row level security;
alter table kut.seasons enable row level security;
alter table kut.profiles enable row level security;
alter table kut.match_sessions enable row level security;
alter table kut.attendance enable row level security;
alter table kut.player_season_state enable row level security;

create policy "authenticated users read players" on kut.players
  for select to authenticated using (true);
create policy "admins manage players" on kut.players
  for all to authenticated using (kut.is_admin()) with check (kut.is_admin());

create policy "authenticated users read seasons" on kut.seasons
  for select to authenticated using (true);
create policy "admins manage seasons" on kut.seasons
  for all to authenticated using (kut.is_admin()) with check (kut.is_admin());

create policy "users read own profile" on kut.profiles
  for select to authenticated using (id = auth.uid());
create policy "admins read profiles" on kut.profiles
  for select to authenticated using (kut.is_admin());
create policy "admins manage profiles" on kut.profiles
  for all to authenticated using (kut.is_admin()) with check (kut.is_admin());

create policy "users read published sessions" on kut.match_sessions
  for select to authenticated using (status = 'published' or kut.is_admin());
create policy "admins manage sessions" on kut.match_sessions
  for all to authenticated using (kut.is_admin()) with check (kut.is_admin());

create policy "users read published attendance" on kut.attendance
  for select to authenticated using (
    exists (
      select 1 from kut.match_sessions
      where match_sessions.id = attendance.session_id
        and (match_sessions.status = 'published' or kut.is_admin())
    )
  );
create policy "admins manage attendance" on kut.attendance
  for all to authenticated using (kut.is_admin()) with check (kut.is_admin());

create policy "authenticated users read player states" on kut.player_season_state
  for select to authenticated using (true);
create policy "admins manage player states" on kut.player_season_state
  for all to authenticated using (kut.is_admin()) with check (kut.is_admin());
