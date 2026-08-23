-- One-time initial roster import and historical attendance backfill, per
-- BUILD_SPEC.md Part 137 ("a migration/seed script is acceptable instead of
-- building a polished import UI" for the initial roster). Idempotent: safe
-- to re-apply against a database that already has some of this data.
--
-- Only players with 2+ appearances across the five source sessions are
-- imported; the user asked for one-off single-appearance names to be left
-- out of the roster for now. Excluded: Bader, Souhail, Meral, Maikel, Nick
-- (there were two different "Nick"s on 07.08, both excluded), Xander, Zak,
-- Jurie, Steffen, Serhat, Stephen. Re-add any of them (with their full
-- attendance history) once they attend a second session.

insert into kut.players (slug, display_name)
values
  ('oussama', 'Oussama'),
  ('freek', 'Freek'),
  ('teize', 'Teize'),
  ('omar', 'Omar'),
  ('amine', 'Amine'),
  ('derk', 'Derk'),
  ('alex', 'Alex'),
  ('quinten', 'Quinten'),
  ('cedric', 'Cedric'),
  ('max', 'Max'),
  ('jui', 'Jui'),
  ('leihko', 'Leihko'),
  ('louis', 'Louis'),
  ('hugo', 'Hugo'),
  ('aram', 'Aram'),
  ('djanco', 'Djanco'),
  ('muaad', 'Muaad'),
  ('nikita', 'Nikita'),
  ('erik', 'Erik'),
  ('melle', 'Melle'),
  ('vitaly', 'Vitaly')
on conflict (slug) do nothing;

-- Every player needs a Live Card edition to be visible/collectible; see the
-- identical pattern in 20260816070000_wallet_starter_and_attendance_rewards.sql.
insert into kut.card_editions (player_id, edition_type, title, is_live)
select id, 'live', display_name || ' Live', true
from kut.players
on conflict do nothing;

-- is_active is computed rather than a literal true: only one season may be
-- active at a time (kut.seasons_one_active_idx), so this stays safe to apply
-- against a database that already has an active season from elsewhere (e.g.
-- a local sandbox reset that already ran supabase/seed.sql).
insert into kut.seasons (id, name, starts_on, is_active)
values (
  'a0000000-0000-4000-8000-000000000000',
  'TFH 2026',
  date '2026-08-03',
  not exists (select 1 from kut.seasons where is_active)
)
on conflict (id) do nothing;

insert into kut.match_sessions (id, season_id, session_date, session_type, status, published_at)
values
  ('a0000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000000', date '2026-08-03', 'monday', 'published', now()),
  ('a0000000-0000-4000-8000-000000000002', 'a0000000-0000-4000-8000-000000000000', date '2026-08-07', 'friday', 'published', now()),
  ('a0000000-0000-4000-8000-000000000003', 'a0000000-0000-4000-8000-000000000000', date '2026-08-10', 'monday', 'published', now()),
  ('a0000000-0000-4000-8000-000000000004', 'a0000000-0000-4000-8000-000000000000', date '2026-08-14', 'friday', 'published', now()),
  ('a0000000-0000-4000-8000-000000000005', 'a0000000-0000-4000-8000-000000000000', date '2026-08-17', 'monday', 'published', now())
on conflict (id) do nothing;

-- No goals were recorded on the source attendance sheets, so every row
-- defaults to 0; correct individual entries later via the admin correction
-- flow if goals are recalled.

insert into kut.attendance (session_id, player_id, goals)
select 'a0000000-0000-4000-8000-000000000001', p.id, 0
from kut.players p
where p.slug in ('oussama', 'freek', 'teize', 'omar', 'amine', 'derk', 'alex', 'quinten')
on conflict (session_id, player_id) do nothing;

insert into kut.attendance (session_id, player_id, goals)
select 'a0000000-0000-4000-8000-000000000002', p.id, 0
from kut.players p
where p.slug in (
  'teize', 'alex', 'derk', 'cedric', 'oussama',
  'max', 'jui', 'leihko', 'louis', 'hugo', 'quinten', 'aram', 'djanco', 'muaad', 'nikita'
)
on conflict (session_id, player_id) do nothing;

insert into kut.attendance (session_id, player_id, goals)
select 'a0000000-0000-4000-8000-000000000003', p.id, 0
from kut.players p
where p.slug in ('teize', 'amine', 'oussama', 'erik', 'jui', 'max', 'melle', 'aram')
on conflict (session_id, player_id) do nothing;

insert into kut.attendance (session_id, player_id, goals)
select 'a0000000-0000-4000-8000-000000000004', p.id, 0
from kut.players p
where p.slug in (
  'oussama', 'cedric', 'freek', 'vitaly', 'alex', 'max', 'jui', 'omar',
  'leihko', 'djanco', 'aram', 'louis', 'hugo', 'nikita', 'quinten', 'muaad'
)
on conflict (session_id, player_id) do nothing;

insert into kut.attendance (session_id, player_id, goals)
select 'a0000000-0000-4000-8000-000000000005', p.id, 0
from kut.players p
where p.slug in ('teize', 'melle', 'erik', 'freek', 'vitaly', 'aram')
on conflict (session_id, player_id) do nothing;

-- kut.rebuild_season() requires an authenticated admin session (kut.is_admin()
-- reads auth.uid()), which a migration does not have. Extract its computation
-- into an internal, ungated core so this one-time backfill can call the exact
-- same canonical formula instead of duplicating it — see BUILD_SPEC.md Part 10
-- ("one canonical calculation module").
create or replace function kut._rebuild_season_core(p_season_id uuid)
returns integer
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
declare
  v_player record;
  v_week record;
  v_activity numeric := 0;
  v_form numeric := 0;
  v_appearances integer;
  v_goals integer;
  v_activity_ovr numeric;
  v_live_ovr integer;
  v_shooting_bonus integer;
  v_rebuilt_count integer := 0;
begin
  if not exists (select 1 from kut.seasons where id = p_season_id) then
    raise exception 'season not found' using errcode = 'P0002';
  end if;

  for v_player in select id, archetype from kut.players loop
    v_activity := 0;
    v_form := 0;
    v_goals := 0;

    for v_week in
      select date_trunc('week', session_date)::date as week_start
      from kut.match_sessions
      where season_id = p_season_id and status = 'published'
      group by date_trunc('week', session_date)::date
      order by week_start
    loop
      select count(*), coalesce(sum(a.goals), 0)
      into v_appearances, v_goals
      from kut.attendance a
      join kut.match_sessions s on s.id = a.session_id
      where a.player_id = v_player.id
        and s.season_id = p_season_id
        and s.status = 'published'
        and date_trunc('week', s.session_date)::date = v_week.week_start;

      v_activity := least(100, greatest(0, v_activity * 0.90 +
        case when v_appearances >= 1 then 14 else 0 end +
        case when v_appearances >= 2 then 3 else 0 end));
      v_form := least(8, greatest(0, v_form * 0.55 +
        1.25 * least(v_goals, 4) + case when v_goals >= 3 then 1 else 0 end));
    end loop;

    v_activity_ovr := 30 + 45 * power(v_activity / 100, 0.80);
    v_live_ovr := least(83, greatest(30, round(v_activity_ovr + round(v_form))::integer));
    v_shooting_bonus := least(8, 2 * greatest(0, v_goals));

    insert into kut.player_season_state (
      player_id, season_id, activity_score, form_score, live_ovr,
      pac, sho, pas, dri, def, phy, rarity_tier, last_week_start
    ) values (
      v_player.id, p_season_id, v_activity, v_form, v_live_ovr,
      least(99, greatest(1, v_live_ovr + case v_player.archetype when 'speedster' then 10 when 'finisher' then 2 when 'defender' then -2 when 'tank' then -8 when 'playmaker' then -2 else 0 end)),
      least(99, greatest(1, v_live_ovr + v_shooting_bonus + case v_player.archetype when 'speedster' then -1 when 'finisher' then 10 when 'playmaker' then -2 when 'defender' then -7 when 'tank' then -2 else 0 end)),
      least(99, greatest(1, v_live_ovr + case v_player.archetype when 'speedster' then -2 when 'finisher' then -3 when 'playmaker' then 10 when 'defender' then -1 when 'tank' then -2 else 0 end)),
      least(99, greatest(1, v_live_ovr + case v_player.archetype when 'speedster' then 4 when 'finisher' then 3 when 'playmaker' then 5 when 'defender' then -4 when 'tank' then -4 else 0 end)),
      least(99, greatest(1, v_live_ovr + case v_player.archetype when 'speedster' then -6 when 'finisher' then -8 when 'playmaker' then -6 when 'defender' then 10 when 'tank' then 4 else 0 end)),
      least(99, greatest(1, v_live_ovr + case v_player.archetype when 'speedster' then -5 when 'finisher' then -4 when 'playmaker' then -5 when 'defender' then 4 when 'tank' then 12 else 0 end)),
      case when v_live_ovr >= 80 then 'elite' when v_live_ovr >= 70 then 'holo' when v_live_ovr >= 60 then 'gold' when v_live_ovr >= 50 then 'silver' when v_live_ovr >= 40 then 'bronze' else 'common' end,
      (select max(date_trunc('week', session_date)::date) from kut.match_sessions where season_id = p_season_id and status = 'published')
    ) on conflict (player_id, season_id) do update set
      activity_score = excluded.activity_score,
      form_score = excluded.form_score,
      live_ovr = excluded.live_ovr,
      pac = excluded.pac, sho = excluded.sho, pas = excluded.pas,
      dri = excluded.dri, def = excluded.def, phy = excluded.phy,
      rarity_tier = excluded.rarity_tier,
      last_week_start = excluded.last_week_start,
      last_rebuilt_at = now();
    v_rebuilt_count := v_rebuilt_count + 1;
  end loop;

  return v_rebuilt_count;
end;
$$;

create or replace function kut.rebuild_season(p_season_id uuid)
returns integer
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
begin
  if not kut.is_admin() then
    raise exception 'admin access required' using errcode = '42501';
  end if;
  return kut._rebuild_season_core(p_season_id);
end;
$$;

revoke execute on function kut._rebuild_season_core(uuid) from public, anon, authenticated;

select kut._rebuild_season_core('a0000000-0000-4000-8000-000000000000');
