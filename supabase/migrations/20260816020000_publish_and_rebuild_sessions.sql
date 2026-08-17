create or replace function kut.rebuild_season(p_season_id uuid)
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
  if not kut.is_admin() then
    raise exception 'admin access required' using errcode = '42501';
  end if;

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
        case when v_appearances >= 1 then 8 else 0 end +
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

create or replace function kut.publish_session(p_session_id uuid)
returns integer
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
declare
  v_season_id uuid;
begin
  if not kut.is_admin() then
    raise exception 'admin access required' using errcode = '42501';
  end if;

  update kut.match_sessions
  set status = 'published', published_at = now()
  where id = p_session_id and status = 'draft'
  returning season_id into v_season_id;

  if v_season_id is null then
    raise exception 'draft session not found' using errcode = 'P0002';
  end if;

  return kut.rebuild_season(v_season_id);
end;
$$;

revoke execute on function kut.rebuild_season(uuid) from public, anon;
revoke execute on function kut.publish_session(uuid) from public, anon;
grant execute on function kut.rebuild_season(uuid) to authenticated, service_role;
grant execute on function kut.publish_session(uuid) to authenticated, service_role;
