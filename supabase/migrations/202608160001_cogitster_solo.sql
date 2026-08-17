-- Cogitster's first server-authoritative vertical slice.
-- Apply with `supabase db push` from the Cogitster app repository.

create extension if not exists pgcrypto;
create schema if not exists cogitster;

grant usage on schema cogitster to anon, authenticated, service_role;

create type cogitster.game_phase as enum (
  'player_turn',
  'player_reveal',
  'ai_placement',
  'ai_reveal',
  'finished'
);

create type cogitster.card_type as enum (
  'Quote',
  'Thinker',
  'Book',
  'Concept',
  'Event'
);

create table cogitster.cards (
  id text primary key,
  card_type cogitster.card_type not null,
  prompt text not null check (char_length(prompt) between 1 and 500),
  chronology_year integer not null,
  meta text not null,
  explanation text not null,
  source_text text not null,
  status text not null default 'draft' check (status in ('draft', 'reviewed', 'published', 'retired')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table cogitster.player_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  display_name text check (char_length(display_name) between 1 and 40),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table cogitster.games (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  difficulty text not null check (difficulty in ('curious', 'scholar', 'oracle')),
  rounds smallint not null check (rounds in (5, 10, 15)),
  current_round smallint not null default 1 check (current_round >= 1),
  phase cogitster.game_phase not null default 'player_turn',
  active_card_id text references cogitster.cards(id) on delete restrict,
  deck text[] not null default '{}',
  player_timeline text[] not null default '{}',
  ai_timeline text[] not null default '{}',
  player_score smallint not null default 0 check (player_score >= 0),
  ai_score smallint not null default 0 check (ai_score >= 0),
  ai_choice smallint check (ai_choice >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  finished_at timestamptz
);

create index games_owner_updated_idx on cogitster.games (owner_id, updated_at desc);
create index cards_published_idx on cogitster.cards (status) where status = 'published';

create table cogitster.game_actions (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references cogitster.games(id) on delete cascade,
  client_action_id uuid not null,
  action text not null check (action in ('place', 'ai_place', 'ai_resolve', 'next')),
  created_at timestamptz not null default now(),
  unique (game_id, client_action_id)
);

create or replace function cogitster.set_updated_at()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger cards_set_updated_at
before update on cogitster.cards
for each row execute function cogitster.set_updated_at();

create trigger player_profiles_set_updated_at
before update on cogitster.player_profiles
for each row execute function cogitster.set_updated_at();

create trigger games_set_updated_at
before update on cogitster.games
for each row execute function cogitster.set_updated_at();

-- Create a private profile on passwordless-email or anonymous sign-up. An
-- anonymous account may later be linked/upgraded through Supabase Auth.
create or replace function cogitster.create_player_profile()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into cogitster.player_profiles (user_id)
  values (new.id)
  on conflict (user_id) do nothing;
  return new;
end;
$$;

create trigger auth_user_created_cogitster_profile
after insert on auth.users
for each row execute function cogitster.create_player_profile();

alter table cogitster.cards enable row level security;
alter table cogitster.player_profiles enable row level security;
alter table cogitster.games enable row level security;
alter table cogitster.game_actions enable row level security;

-- Cards, games, and action logs are served only through Edge Functions. This
-- prevents a browser from reading a future or an opponent's hidden card.
create policy "players read their own profile"
on cogitster.player_profiles for select to authenticated
using ((select auth.uid()) = user_id);

create policy "players update their own profile"
on cogitster.player_profiles for update to authenticated
using ((select auth.uid()) = user_id)
with check ((select auth.uid()) = user_id);

create policy "players insert their own profile"
on cogitster.player_profiles for insert to authenticated
with check ((select auth.uid()) = user_id);

revoke all on all tables in schema cogitster from anon, authenticated;
grant select, insert, update on cogitster.player_profiles to authenticated;
grant all on all tables in schema cogitster to service_role;
