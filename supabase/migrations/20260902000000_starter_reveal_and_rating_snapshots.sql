-- Starter-pack reveal onboarding + weekly rating snapshots for "Top risers".
-- See ADR-031.
--
--   1. kut.player_rating_snapshots -- one immutable-ish row per player per
--      published football week (week_start = player_season_state.last_week_start,
--      which is the season's most recent published week). Written by an AFTER
--      trigger on kut.player_season_state so every rebuild path (publish,
--      correct, reactivate, admin_add_player, set_own_player_archetype) captures
--      a snapshot without duplicating the ADR-024 rating formula. Intra-week
--      rebuilds overwrite the same (player, season, week_start) row, so the
--      prior week's row -- and the delta shown on Home all week -- is stable.
--   2. kut.top_risers -- view: the biggest positive live_ovr change between the
--      two most recent snapshot weeks of the active season. Fallers are omitted.
--   3. kut.profiles.starter_opened_at -- marks that a member has seen the
--      one-time "open your starter pack" reveal at /welcome. Backfilled from
--      starter_claimed_at so existing members are not forced through the gate.
--   4. kut.mark_starter_opened() -- member RPC the /welcome "Open" button calls;
--      grants the starter first if somehow still unclaimed (legacy accounts),
--      then stamps starter_opened_at.
--   5. kut.my_pack_opening_results widened with players.photo_path so the shared
--      pack-reveal animation can show card photos (append-only).
--
-- Rollback:
--   drop view kut.top_risers;
--   drop trigger player_season_state_capture_snapshot on kut.player_season_state;
--   drop function kut.capture_rating_snapshot();
--   drop table kut.player_rating_snapshots;
--   drop function kut.mark_starter_opened();
--   alter table kut.profiles drop column starter_opened_at;
--   -- restore kut.my_pack_opening_results to its 20260816070400 body (drop the
--   -- trailing players.photo_path column).

-- 1. Weekly rating snapshots -----------------------------------------------------
create table kut.player_rating_snapshots (
  player_id uuid not null references kut.players(id) on delete cascade,
  season_id uuid not null references kut.seasons(id) on delete cascade,
  week_start date not null,
  live_ovr integer not null check (live_ovr between 30 and 83),
  rarity_tier text not null check (rarity_tier in ('common', 'bronze', 'silver', 'gold', 'holo', 'elite')),
  captured_at timestamptz not null default now(),
  primary key (player_id, season_id, week_start)
);

create index player_rating_snapshots_season_week_idx
  on kut.player_rating_snapshots (season_id, week_start desc);

grant select on kut.player_rating_snapshots to authenticated, service_role;

alter table kut.player_rating_snapshots enable row level security;

-- The whole app is member-only (ADR-020); no client write path.
create policy "authenticated users read rating snapshots" on kut.player_rating_snapshots
  for select to authenticated using (true);
create policy "admins manage rating snapshots" on kut.player_rating_snapshots
  for all to authenticated using (kut.is_admin()) with check (kut.is_admin());

create or replace function kut.capture_rating_snapshot()
returns trigger
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
begin
  if new.last_week_start is not null then
    insert into kut.player_rating_snapshots (player_id, season_id, week_start, live_ovr, rarity_tier)
    values (new.player_id, new.season_id, new.last_week_start, new.live_ovr, new.rarity_tier)
    on conflict (player_id, season_id, week_start) do update set
      live_ovr = excluded.live_ovr,
      rarity_tier = excluded.rarity_tier,
      captured_at = now();
  end if;
  return new;
end;
$$;

revoke execute on function kut.capture_rating_snapshot() from public, anon, authenticated;

create trigger player_season_state_capture_snapshot
  after insert or update on kut.player_season_state
  for each row execute function kut.capture_rating_snapshot();

-- Seed the current week so the feature is not blank until the next publish. Prior
-- weeks cannot be reconstructed without re-running the fold; the view degrades to
-- an empty result (Home shows an explanatory empty state) until a second week of
-- snapshots exists.
insert into kut.player_rating_snapshots (player_id, season_id, week_start, live_ovr, rarity_tier)
select player_id, season_id, last_week_start, live_ovr, rarity_tier
from kut.player_season_state
where last_week_start is not null
on conflict do nothing;

-- 2. Top risers view ----------------------------------------------------------
create view kut.top_risers
with (security_invoker = true, security_barrier = true)
as
with ranked_weeks as (
  select season_id, week_start,
    dense_rank() over (partition by season_id order by week_start desc) as recency
  from (select distinct season_id, week_start from kut.player_rating_snapshots) distinct_weeks
),
current_week as (
  select snap.player_id, snap.season_id, snap.live_ovr
  from kut.player_rating_snapshots snap
  join ranked_weeks rw on rw.season_id = snap.season_id and rw.week_start = snap.week_start and rw.recency = 1
),
previous_week as (
  select snap.player_id, snap.season_id, snap.live_ovr
  from kut.player_rating_snapshots snap
  join ranked_weeks rw on rw.season_id = snap.season_id and rw.week_start = snap.week_start and rw.recency = 2
)
select
  player.id,
  player.slug,
  player.display_name,
  player.archetype,
  player.photo_path,
  state.live_ovr,
  state.pac, state.sho, state.pas, state.dri, state.def, state.phy,
  state.rarity_tier,
  (current_week.live_ovr - previous_week.live_ovr) as ovr_delta
from current_week
join previous_week
  on previous_week.player_id = current_week.player_id
 and previous_week.season_id = current_week.season_id
join kut.seasons season on season.id = current_week.season_id and season.is_active
join kut.players player on player.id = current_week.player_id
join kut.player_season_state state
  on state.player_id = current_week.player_id
 and state.season_id = current_week.season_id
where player.is_active
  and player.is_collectible
  and (current_week.live_ovr - previous_week.live_ovr) > 0
order by ovr_delta desc, state.live_ovr desc, player.display_name;

revoke all on kut.top_risers from public;
grant select on kut.top_risers to authenticated, service_role;

-- 3. Starter-reveal marker --------------------------------------------------
alter table kut.profiles add column starter_opened_at timestamptz;

-- Established members already have their starter; don't force them through the
-- one-time reveal gate. Only genuinely new members (starter granted at invite
-- claim, starter_opened_at still null) will be gated into /welcome.
update kut.profiles
set starter_opened_at = starter_claimed_at
where starter_claimed_at is not null;

-- 4. mark_starter_opened RPC ----------------------------------------------------
create or replace function kut.mark_starter_opened()
returns void
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  perform 1 from kut.profiles where id = v_user_id and not is_disabled for update;
  if not found then
    raise exception 'active profile not found' using errcode = 'P0002';
  end if;

  -- Legacy safety net: an account that never claimed still gets its starter here
  -- (replaces the old homepage StarterClaimForm). grant_starter_pack raises
  -- P0001 if already claimed, so guard on the marker.
  if not exists (
    select 1 from kut.profiles where id = v_user_id and starter_claimed_at is not null
  ) then
    perform kut.grant_starter_pack(v_user_id);
  end if;

  update kut.profiles
  set starter_opened_at = now()
  where id = v_user_id and starter_opened_at is null;
end;
$$;

revoke execute on function kut.mark_starter_opened() from public, anon;
grant execute on function kut.mark_starter_opened() to authenticated, service_role;

-- 5. Widen the pack-opening result view with the player photo ------------------
create or replace view kut.my_pack_opening_results
with (security_invoker = true, security_barrier = true)
as
select
  opening.id as opening_id,
  opening.opened_at,
  opening.price_paid,
  pack.slug as pack_slug,
  pack.title as pack_title,
  result.slot,
  card.id as card_id,
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
  player.photo_path
from kut.pack_openings opening
join kut.pack_definitions pack on pack.id = opening.pack_id
join kut.pack_opening_cards result on result.opening_id = opening.id
join kut.user_cards card on card.id = result.card_id
join kut.card_editions edition on edition.id = card.edition_id
join kut.players player on player.id = edition.player_id
left join kut.seasons active_season on active_season.is_active
left join kut.player_season_state state
  on state.player_id = player.id
  and state.season_id = active_season.id
where opening.user_id = auth.uid();

revoke all on kut.my_pack_opening_results from public;
grant select on kut.my_pack_opening_results to authenticated, service_role;
