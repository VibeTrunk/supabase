-- Midweek Madness, migration A: the schema and squad entry (BUILD_SPEC §44.1,
-- §44.2, §44.9; ADR-089, ADR-091).
--
-- A weekly 5-card squad knockout. This migration adds only what a member needs
-- to enter; the engine, the lazy worker, the reveal views and the payout come
-- in later migrations, each on its own (ADR-070). Nothing creates a tournament
-- yet, so until the worker ships `save_midweek_squad` has nothing to save to,
-- and the launch switch starts off.
--
--   1. kut.midweek_config             -- one row: the launch and pause switch
--                                        (`enabled`, default false).
--   2. kut.midweek_tournaments        -- one per football week: lock time,
--                                        published seed hash, status, and the
--                                        seed itself once complete.
--   3. kut.midweek_tournament_secrets -- the seed from creation; service role
--                                        only (ADR-091).
--   4. kut.midweek_squads / kut.midweek_squad_cards -- a member's saved squad:
--                                        1-5 Card Copies, one per Player.
--   5. kut.midweek_opt_outs           -- members who never take part.
--   6. kut.save_midweek_squad / kut.set_midweek_opt_out -- the member RPCs.
--   7. kut.midweek_current / kut.midweek_tournaments_public /
--      kut.my_midweek_squad            -- definer projections gated on
--                                        kut.is_active_member() (ADR-079).
--
-- Two tournaments matter to the page at once: the worker opens next week's as
-- soon as one is complete, skipped or void, so from Wednesday night
-- midweek_current is already next week's, while the page still reports last
-- week's outcome (design/midweek/HANDOFF.md, owner decision D4). Hence
-- midweek_tournaments_public, every tournament newest first; the engine
-- migration appends the champion to it. A skip or void carries its reason as a
-- code, because members get different wording for each.
--
-- Squads stay private before the lock: a member reads only their own. Nothing
-- here shows another member's squad; the reveal views do that from round 1.
--
-- Tier: additive (docs/OPERATIONS.md) -- new tables, functions and views only.
-- No existing row is read-modified, and no coin moves.
--
-- Rollback:
--   drop view kut.my_midweek_squad; drop view kut.midweek_tournaments_public;
--   drop view kut.midweek_current;
--   drop function kut.set_midweek_opt_out(boolean);
--   drop function kut.save_midweek_squad(uuid[]);
--   drop table kut.midweek_opt_outs; drop table kut.midweek_squad_cards;
--   drop table kut.midweek_squads; drop table kut.midweek_tournament_secrets;
--   drop table kut.midweek_tournaments; drop table kut.midweek_config;

-- 1. Tables ------------------------------------------------------------------

create table kut.midweek_config (
  -- A single row: the key can only ever be true.
  id boolean primary key default true check (id),
  enabled boolean not null default false,
  updated_at timestamptz not null default now(),
  updated_by uuid references kut.profiles(id) on delete set null
);
insert into kut.midweek_config (id, enabled) values (true, false);

create table kut.midweek_tournaments (
  id uuid primary key default gen_random_uuid(),
  -- ISO Monday of the football week (BUILD_SPEC §9); one tournament per week.
  week_start date not null unique check (extract(isodow from week_start) = 1),
  -- Wednesday 20:00 Europe/Amsterdam of that week (src/game/midweek/schedule.ts).
  lock_at timestamptz not null,
  -- sha256 of the secret seed, published from creation (commit and reveal).
  seed_hash text not null check (seed_hash ~ '^[0-9a-f]{64}$'),
  status text not null default 'open'
    check (status in ('open', 'skipped', 'simulated', 'complete', 'void')),
  -- Why a week didn't run, as a code so each gets its own member wording: a
  -- club break or too few entrants (skipped), or an admin void.
  status_reason text check (status_reason in ('club_break', 'too_few_entrants', 'admin_void')),
  -- The admin's own words for a void. Members read it, and the void form says so.
  void_note text check (void_note is null or char_length(void_note) between 3 and 200),
  -- Known once the bracket is drawn at the lock.
  rounds smallint check (rounds is null or rounds between 1 and 10),
  final_reveal_at timestamptz,
  -- The seed, copied here only when the tournament is complete.
  seed text check (seed is null or seed ~ '^[0-9a-f]{64}$'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (seed is null or status = 'complete'),
  check ((status in ('skipped', 'void')) = (status_reason is not null)),
  check (status <> 'skipped' or status_reason in ('club_break', 'too_few_entrants')),
  check (status <> 'void' or status_reason = 'admin_void'),
  check ((void_note is not null) = (status = 'void')),
  check ((rounds is null) = (final_reveal_at is null))
);
create index midweek_tournaments_open_idx on kut.midweek_tournaments (week_start) where status = 'open';

create table kut.midweek_tournament_secrets (
  tournament_id uuid primary key references kut.midweek_tournaments(id) on delete cascade,
  seed text not null check (seed ~ '^[0-9a-f]{64}$')
);

create table kut.midweek_squads (
  id uuid primary key default gen_random_uuid(),
  tournament_id uuid not null references kut.midweek_tournaments(id) on delete cascade,
  user_id uuid not null references kut.profiles(id) on delete cascade,
  saved_at timestamptz not null default now(),
  unique (tournament_id, user_id)
);
create index midweek_squads_user_idx on kut.midweek_squads (user_id);

create table kut.midweek_squad_cards (
  squad_id uuid not null references kut.midweek_squads(id) on delete cascade,
  slot smallint not null check (slot between 1 and 5),
  card_id uuid not null references kut.user_cards(id) on delete cascade,
  -- Denormalised from the card's edition so one Player fills one slot.
  player_id uuid not null references kut.players(id) on delete restrict,
  primary key (squad_id, slot),
  unique (squad_id, card_id),
  unique (squad_id, player_id)
);

create table kut.midweek_opt_outs (
  user_id uuid primary key references kut.profiles(id) on delete cascade,
  opted_out_at timestamptz not null default now()
);

-- Members never read or write these tables directly: the RPCs below write, and
-- the gated projections read. The seed table is the service role's alone.
alter table kut.midweek_config enable row level security;
alter table kut.midweek_tournaments enable row level security;
alter table kut.midweek_tournament_secrets enable row level security;
alter table kut.midweek_squads enable row level security;
alter table kut.midweek_squad_cards enable row level security;
alter table kut.midweek_opt_outs enable row level security;
revoke all on kut.midweek_config, kut.midweek_tournaments, kut.midweek_tournament_secrets,
  kut.midweek_squads, kut.midweek_squad_cards, kut.midweek_opt_outs
  from public, anon, authenticated;
grant select on kut.midweek_config, kut.midweek_tournaments, kut.midweek_tournament_secrets,
  kut.midweek_squads, kut.midweek_squad_cards, kut.midweek_opt_outs
  to service_role;

-- 2. Member RPCs --------------------------------------------------------------

-- Saves the caller's squad for the open tournament, replacing any earlier one.
-- The cards are 1-5 active Card Copies the caller owns, one per Player; a card
-- listed on the market or held in trade escrow is still owned and may play
-- (ADR-089). Refused once now() reaches the lock.
create function kut.save_midweek_squad(p_card_ids uuid[])
returns jsonb language plpgsql security definer set search_path = kut, pg_catalog as $$
declare
  v_user uuid := auth.uid();
  v_count integer := coalesce(cardinality(p_card_ids), 0);
  v_tournament record; v_squad uuid; v_owned integer; v_players integer;
begin
  if v_user is null or not exists (select 1 from kut.profiles where id = v_user and not is_disabled) then
    raise exception 'an active KUT account is required' using errcode = '42501';
  end if;
  if exists (select 1 from kut.midweek_opt_outs where user_id = v_user) then
    raise exception 'you have opted out of Midweek Madness' using errcode = 'P0001';
  end if;
  if v_count not between 1 and 5
    or array_position(p_card_ids, null) is not null
    or (select count(distinct card_id) from unnest(p_card_ids) card_id) <> v_count
  then
    raise exception 'pick between one and five different cards' using errcode = '22023';
  end if;

  -- A shared lock: saves run side by side, but the worker's lock step (which
  -- takes the row for update) waits for them, and they wait for it.
  select id, week_start, lock_at into v_tournament
  from kut.midweek_tournaments
  where status = 'open'
  order by week_start
  limit 1
  for share;
  if not found then raise exception 'no Midweek Madness tournament is open' using errcode = 'P0002'; end if;
  if now() >= v_tournament.lock_at then raise exception 'squads are locked' using errcode = 'P0001'; end if;

  select count(*), count(distinct edition.player_id) into v_owned, v_players
  from kut.user_cards card
  join kut.card_editions edition on edition.id = card.edition_id
  where card.id = any(p_card_ids) and card.owner_id = v_user and card.burned_at is null;
  if v_owned <> v_count then
    raise exception 'you can only pick active cards you own' using errcode = '22023';
  end if;
  if v_players <> v_count then
    raise exception 'each card must be a different Player' using errcode = '22023';
  end if;

  insert into kut.midweek_squads (tournament_id, user_id)
  values (v_tournament.id, v_user)
  on conflict (tournament_id, user_id) do update set saved_at = now()
  returning id into v_squad;
  delete from kut.midweek_squad_cards where squad_id = v_squad;
  insert into kut.midweek_squad_cards (squad_id, slot, card_id, player_id)
  select v_squad, picked.slot::smallint, card.id, edition.player_id
  from unnest(p_card_ids) with ordinality as picked(card_id, slot)
  join kut.user_cards card on card.id = picked.card_id
  join kut.card_editions edition on edition.id = card.edition_id;

  return jsonb_build_object(
    'tournament_id', v_tournament.id,
    'week_start', v_tournament.week_start,
    'lock_at', v_tournament.lock_at,
    'cards', v_count
  );
end $$;
revoke all on function kut.save_midweek_squad(uuid[]) from public, anon;
grant execute on function kut.save_midweek_squad(uuid[]) to authenticated, service_role;

-- Opting out takes the caller out entirely: never picked, never auto-entered,
-- never shown (ADR-091). A squad already saved for a tournament that has not
-- locked yet is withdrawn with it. Opting back in only removes the flag.
create function kut.set_midweek_opt_out(p_opt_out boolean)
returns jsonb language plpgsql security definer set search_path = kut, pg_catalog as $$
declare v_user uuid := auth.uid();
begin
  if v_user is null or not exists (select 1 from kut.profiles where id = v_user and not is_disabled) then
    raise exception 'an active KUT account is required' using errcode = '42501';
  end if;
  if p_opt_out is null then raise exception 'say whether to opt out' using errcode = '22023'; end if;

  if p_opt_out then
    insert into kut.midweek_opt_outs (user_id) values (v_user) on conflict (user_id) do nothing;
    delete from kut.midweek_squads squad
    using kut.midweek_tournaments tournament
    where squad.tournament_id = tournament.id and squad.user_id = v_user
      and tournament.status = 'open' and now() < tournament.lock_at;
  else
    delete from kut.midweek_opt_outs where user_id = v_user;
  end if;
  return jsonb_build_object('opted_out', p_opt_out);
end $$;
revoke all on function kut.set_midweek_opt_out(boolean) from public, anon;
grant execute on function kut.set_midweek_opt_out(boolean) to authenticated, service_role;

-- 3. Projections ----------------------------------------------------------------
-- Definer views over tables members cannot read, so each is gated on
-- kut.is_active_member() as ADR-079 gates the others: a denied caller reads
-- zero rows, never an error. Columns are only ever appended.

-- The launch switch, the current (latest) tournament and the caller's opt-out.
-- With no tournament yet, one row still comes back so a page can read
-- `enabled`. The seed column is null until the tournament is complete.
create view kut.midweek_current
with (security_invoker = false, security_barrier = true)
as
select * from (
  select
    config.enabled,
    tournament.id as tournament_id,
    tournament.week_start,
    tournament.lock_at,
    tournament.seed_hash,
    tournament.status,
    tournament.status_reason,
    tournament.void_note,
    tournament.rounds,
    tournament.final_reveal_at,
    tournament.seed,
    exists (select 1 from kut.midweek_opt_outs o where o.user_id = auth.uid()) as opted_out
  from kut.midweek_config config
  left join lateral (
    select * from kut.midweek_tournaments order by week_start desc limit 1
  ) tournament on true
) gated
where kut.is_active_member();

comment on view kut.midweek_current is
  'ADR-089: the Midweek Madness launch switch, the latest tournament (seed hash from creation, seed only once complete) and the caller''s opt-out. Gated on kut.is_active_member() (ADR-079).';
revoke all on kut.midweek_current from public, anon;
grant select on kut.midweek_current to authenticated, service_role;

-- Every tournament, newest first by week, so a page can report last week's
-- outcome after next week's has opened. No squad or result data yet: the
-- engine migration appends the champion here, and the reveal views carry the
-- rest.
create view kut.midweek_tournaments_public
with (security_invoker = false, security_barrier = true)
as
select
  tournament.id as tournament_id,
  tournament.week_start,
  tournament.lock_at,
  tournament.seed_hash,
  tournament.status,
  tournament.status_reason,
  tournament.void_note,
  tournament.rounds,
  tournament.final_reveal_at,
  tournament.seed
from kut.midweek_tournaments tournament
where kut.is_active_member()
order by tournament.week_start desc;

comment on view kut.midweek_tournaments_public is
  'ADR-089: every Midweek Madness tournament (status, skip or void reason, reveal times, the seed only once complete), for reporting last week''s outcome. Gated on kut.is_active_member() (ADR-079).';
revoke all on kut.midweek_tournaments_public from public, anon;
grant select on kut.midweek_tournaments_public to authenticated, service_role;

-- The caller's own saved squads, one row per card. Never anyone else's: other
-- squads appear only through the reveal views, from round 1 (ADR-091).
create view kut.my_midweek_squad
with (security_invoker = false, security_barrier = true)
as
select
  tournament.id as tournament_id,
  tournament.week_start,
  squad.saved_at,
  squad_card.slot,
  squad_card.card_id,
  squad_card.player_id
from kut.midweek_squads squad
join kut.midweek_tournaments tournament on tournament.id = squad.tournament_id
join kut.midweek_squad_cards squad_card on squad_card.squad_id = squad.id
where squad.user_id = auth.uid()
  and kut.is_active_member();

comment on view kut.my_midweek_squad is
  'ADR-089: the caller''s own Midweek Madness squads, one row per card and slot. Gated on kut.is_active_member() (ADR-079).';
revoke all on kut.my_midweek_squad from public, anon;
grant select on kut.my_midweek_squad to authenticated, service_role;
