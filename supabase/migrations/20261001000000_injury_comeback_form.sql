-- ADR-083: a Comeback Form boost for a Player returning from injury mode.
--
-- ADR-082 protects an injured Player's Activity for every week they check in.
-- This adds the reward for coming back: the first published session a Player
-- attends after an injury period, with at least 3 protected weeks before it,
-- carries a Form input of
--
--     least(2, 0.25 x protected_weeks)
--
-- so 3 weeks give 0.75, 4 give 1, and 8 or more give the 2 cap. The input ages
-- exactly like a session's goals-and-kudos input (100/75/50/25/0 % over the
-- next four published v2 sessions) and counts under the unchanged Form cap of 8.
-- It is Form, so it lifts the card for a while and never permanently.
--
--   1. kut.comeback_form_inputs -- DERIVED rows, one per (Player, return
--                              session). kut._rebuild_season_core deletes and
--                              re-inserts a season's rows from the facts
--                              (injury_check_ins + attendance) on every
--                              rebuild, exactly as it re-derives
--                              player_rating_snapshots, so the rebuild stays
--                              deterministic (Part L #16). Members read it
--                              under kut.is_active_member() (ADR-079), because
--                              the rating story shows every player's Form.
--   2. kut._rebuild_season_core -- re-emitted from 20260930000000 with two
--                              changes: the derivation above at the start, and
--                              comeback rows unioned into the v2 session inputs.
--   3. kut.player_form_contributions -- comeback rows unioned in, so the rating
--                              story's rows still sum to form_score (ADR-074).
--                              Two columns APPENDED: source ('session' or
--                              'comeback') and protected_weeks.
--
-- Rules, and why:
--   * "Protected weeks" counts only check-ins for weeks BEFORE the return week.
--     A check-in in the week the Player returns protects nothing, because a
--     week with an appearance is always scored normally (ADR-082).
--   * The return session is the first published session attended strictly
--     after started_on, ordered (session_date, session_type, id) as the engine
--     orders sessions. It must be a v2 session in the season being rebuilt.
--   * Periods that share a return session (an admin ended one and started
--     another without the Player playing in between) are summed into ONE
--     comeback, still capped at 2, so a return is never rewarded twice.
--
-- Tier: data-changing (docs/OPERATIONS.md) -- a rating-formula change. No row
-- is written by the migration. Output only changes for a Player with an injury
-- period, 3+ protected weeks and a return session.
--
-- Rollback:
--   drop view kut.player_form_contributions;  -- create or replace cannot drop
--     the two appended columns. Nothing else references the view (ADR-074).
--   re-run its `create view`, comment, revoke and grant lines from
--     20260926000000_trade_log_rating_story_listing_duration.sql;
--   re-run the `create or replace function kut._rebuild_season_core` block from
--     20260930000000_injury_protection.sql;
--   drop table kut.comeback_form_inputs;
--   then rebuild the active season so no comeback Form remains.

-- 1. Derived comeback inputs ----------------------------------------------------

create table kut.comeback_form_inputs (
  player_id uuid not null references kut.players(id) on delete cascade,
  season_id uuid not null references kut.seasons(id) on delete cascade,
  -- The return session. Derived rows follow their session.
  session_id uuid not null references kut.match_sessions(id) on delete cascade,
  protected_weeks integer not null check (protected_weeks >= 3),
  form_input numeric(4,2) not null check (form_input > 0 and form_input <= 2),
  primary key (player_id, session_id)
);
create index comeback_form_inputs_season_idx on kut.comeback_form_inputs (season_id);

alter table kut.comeback_form_inputs enable row level security;
create policy "active members read comeback inputs" on kut.comeback_form_inputs
  for select to authenticated using (kut.is_active_member());
revoke all on kut.comeback_form_inputs from public, anon;
grant select on kut.comeback_form_inputs to authenticated, service_role;

-- 2. Rating engine ------------------------------------------------------------------
-- Body verbatim from 20260930000000_injury_protection.sql, plus the two ADR-083
-- changes marked in place.

create or replace function kut._rebuild_season_core(p_season_id uuid)
returns integer language plpgsql security definer set search_path=kut,pg_catalog as $$
declare
  v_player record; v_week record; v_cutover date; v_activity numeric; v_legacy numeric; v_form numeric;
  v_appearances integer; v_goals integer; v_v2_count integer; v_contributions numeric;
  v_activity_ovr numeric; v_live integer; v_shoot integer; v_tier text; v_count integer:=0; v_last_week date;
begin
  select v2_starts_week into v_cutover from kut.season_rating_rules where season_id=p_season_id;
  if v_cutover is null then raise exception 'season rating rules not found' using errcode='P0002'; end if;
  delete from kut.player_rating_snapshots where season_id=p_season_id;
  -- ADR-083: re-derive this season's comeback inputs from the facts (injury
  -- check-ins and attendance), exactly as the snapshots are re-derived.
  delete from kut.comeback_form_inputs where season_id=p_season_id;
  insert into kut.comeback_form_inputs(player_id,season_id,session_id,protected_weeks,form_input)
  select per_period.player_id,p_season_id,per_period.session_id,sum(per_period.weeks)::integer,least(2,0.25*sum(per_period.weeks))
  from (
    select period.player_id,ret.id session_id,
      (select count(*) from kut.injury_check_ins c where c.period_id=period.id and c.week_start<date_trunc('week',ret.session_date)::date) weeks
    from kut.injury_periods period
    cross join lateral (
      select s.id,s.session_date,s.season_id,s.rating_rules_version from kut.attendance a join kut.match_sessions s on s.id=a.session_id
      where a.player_id=period.player_id and s.status='published' and s.session_date>period.started_on
      order by s.session_date,s.session_type,s.id limit 1
    ) ret
    where ret.season_id=p_season_id and ret.rating_rules_version=2
  ) per_period
  group by per_period.player_id,per_period.session_id
  having sum(per_period.weeks)>=3;
  for v_player in select id,archetype from kut.players loop
    v_activity:=0; v_legacy:=0; v_form:=0; v_goals:=0; v_last_week:=null;
    for v_week in select date_trunc('week',session_date)::date week_start
      from kut.match_sessions where season_id=p_season_id and status='published'
      group by 1 order by 1 loop
      v_last_week:=v_week.week_start;
      select count(*) into v_appearances from kut.attendance a join kut.match_sessions s on s.id=a.session_id
      where a.player_id=v_player.id and s.season_id=p_season_id and s.status='published' and date_trunc('week',s.session_date)::date=v_week.week_start;
      -- ADR-082: an injury check-in protects a week he did not play. Activity
      -- carries over unchanged, as in a week with no TFH session at all.
      if v_appearances=0 and exists(select 1 from kut.injury_check_ins c where c.player_id=v_player.id and c.week_start=v_week.week_start) then
        null;
      else
        v_activity:=least(100,greatest(0,v_activity*.90+case when v_appearances>=1 then 14 else 0 end+case when v_appearances>=2 then 3 else 0 end));
      end if;
      if v_week.week_start<v_cutover then
        select coalesce(sum(a.goals),0) into v_goals from kut.attendance a join kut.match_sessions s on s.id=a.session_id
        where a.player_id=v_player.id and s.season_id=p_season_id and s.status='published' and date_trunc('week',s.session_date)::date=v_week.week_start;
        v_legacy:=least(8,greatest(0,v_legacy*.55+1.25*least(v_goals,4)+case when v_goals>=3 then 1 else 0 end));
        v_form:=v_legacy;
      else
        select count(*) into v_v2_count from kut.match_sessions s where s.season_id=p_season_id and s.status='published' and s.rating_rules_version=2 and s.session_date<(v_week.week_start+7);
        select coalesce(sum(result.session_input * case age when 0 then 1 when 1 then .75 when 2 then .5 when 3 then .25 else 0 end),0)
        into v_contributions from (
          select r.session_input,(select count(*) from kut.match_sessions later where later.season_id=p_season_id and later.status='published' and later.rating_rules_version=2
            and (later.session_date,later.session_type,later.id)>(s.session_date,s.session_type,s.id) and later.session_date<(v_week.week_start+7))::integer age
          from (select session_id,session_input from kut.session_report_results where player_id=v_player.id
                union all  -- ADR-083: a comeback input ages exactly like a session input
                select session_id,form_input from kut.comeback_form_inputs where player_id=v_player.id and season_id=p_season_id) r
          join kut.match_sessions s on s.id=r.session_id
          where s.season_id=p_season_id and s.status='published' and s.rating_rules_version=2 and s.session_date<(v_week.week_start+7)
        ) result;
        v_form:=least(8,greatest(0,v_contributions+v_legacy*case v_v2_count when 1 then .75 when 2 then .5 when 3 then .25 else 0 end));
        select coalesce(sum(r.effective_goals),0) into v_goals from kut.session_report_results r join kut.match_sessions s on s.id=r.session_id
        where r.player_id=v_player.id and s.season_id=p_season_id and s.status='published' and date_trunc('week',s.session_date)::date=v_week.week_start;
      end if;
      v_activity_ovr:=30+45*power(v_activity/100,.80); v_live:=least(83,greatest(30,round(v_activity_ovr+floor(v_form+.5))::integer));
      v_shoot:=least(8,2*greatest(0,v_goals));
      v_tier:=case when v_live>=80 then 'elite' when v_live>=70 then 'holo' when v_live>=60 then 'gold' when v_live>=50 then 'silver' when v_live>=40 then 'bronze' else 'common' end;
      insert into kut.player_rating_snapshots(player_id,season_id,week_start,live_ovr,rarity_tier)
      values(v_player.id,p_season_id,v_week.week_start,v_live,v_tier)
      on conflict(player_id,season_id,week_start) do update set live_ovr=excluded.live_ovr,rarity_tier=excluded.rarity_tier,captured_at=now();
    end loop;
    if v_last_week is null then v_live:=30; v_tier:='common'; v_activity:=0; v_form:=0; v_goals:=0; v_shoot:=0; end if;
    insert into kut.player_season_state(player_id,season_id,activity_score,form_score,live_ovr,pac,sho,pas,dri,def,phy,rarity_tier,last_week_start)
    values(v_player.id,p_season_id,v_activity,v_form,v_live,
      least(99,greatest(1,v_live+case v_player.archetype when 'speedster' then 10 when 'finisher' then 2 when 'defender' then -2 when 'tank' then -8 when 'playmaker' then -2 when 'goalkeeper' then -6 else 0 end)),
      least(99,greatest(1,v_live+v_shoot+case v_player.archetype when 'speedster' then -1 when 'finisher' then 10 when 'playmaker' then -2 when 'defender' then -7 when 'tank' then -2 when 'goalkeeper' then -12 else 0 end)),
      least(99,greatest(1,v_live+case v_player.archetype when 'speedster' then -2 when 'finisher' then -3 when 'playmaker' then 10 when 'defender' then -1 when 'tank' then -2 when 'goalkeeper' then 0 else 0 end)),
      least(99,greatest(1,v_live+case v_player.archetype when 'speedster' then 4 when 'finisher' then 3 when 'playmaker' then 5 when 'defender' then -4 when 'tank' then -4 when 'goalkeeper' then -8 else 0 end)),
      least(99,greatest(1,v_live+case v_player.archetype when 'speedster' then -6 when 'finisher' then -8 when 'playmaker' then -6 when 'defender' then 10 when 'tank' then 4 when 'goalkeeper' then 14 else 0 end)),
      least(99,greatest(1,v_live+case v_player.archetype when 'speedster' then -5 when 'finisher' then -4 when 'playmaker' then -5 when 'defender' then 4 when 'tank' then 12 when 'goalkeeper' then 12 else 0 end)),v_tier,v_last_week)
    on conflict(player_id,season_id) do update set activity_score=excluded.activity_score,form_score=excluded.form_score,live_ovr=excluded.live_ovr,pac=excluded.pac,sho=excluded.sho,pas=excluded.pas,dri=excluded.dri,def=excluded.def,phy=excluded.phy,rarity_tier=excluded.rarity_tier,last_week_start=excluded.last_week_start,last_rebuilt_at=now();
    v_count:=v_count+1;
  end loop;
  return v_count;
end $$;
revoke execute on function kut._rebuild_season_core(uuid) from public,anon,authenticated;

-- 3. The rating story's contributions -------------------------------------------------
-- Body from 20260926000000_trade_log_rating_story_listing_duration.sql, with the
-- source table widened to session results UNION ALL comeback inputs, and two
-- columns appended (create or replace view can only append). The session-age
-- ladder is still expressed a second time here, as ADR-074 recorded; it is
-- pinned for sessions by rating_breakdown.test.sql and for comebacks by
-- injury_comeback.test.sql, both asserting the summed rows equal form_score.
-- Still security_invoker = true, and still never joins kut.session_kudos or
-- kut.session_surveys.

create or replace view kut.player_form_contributions
with (security_invoker = true, security_barrier = true)
as
select
  result.player_id,
  result.session_id,
  session.season_id,
  session.session_date,
  session.session_type,
  result.effective_goals,
  result.goal_form,
  result.kudos_form,
  result.session_input,
  age.value                                  as session_age,
  weight.value                               as weight,
  result.session_input * weight.value        as weighted_contribution,
  categories.titles                          as recognized_categories,
  result.source,
  result.protected_weeks
from (
  select
    r.player_id, r.session_id, r.effective_goals, r.goal_form, r.kudos_form,
    r.session_input, r.qualified_category_ids,
    'session'::text as source, null::integer as protected_weeks
  from kut.session_report_results r
  union all
  select
    c.player_id, c.session_id, null::integer, 0::numeric(4,2), 0::numeric(4,2),
    c.form_input, '{}'::uuid[],
    'comeback'::text, c.protected_weeks
  from kut.comeback_form_inputs c
) result
join kut.match_sessions session on session.id = result.session_id
join kut.seasons season on season.id = session.season_id
cross join lateral (
  -- Age in SESSIONS, not weeks: the count of later published v2 sessions,
  -- ordered exactly as _rebuild_season_core orders them. RATING_BALANCE_REVIEW
  -- is explicit that four sessions must never be equated with four weeks.
  select count(*)::integer as value
  from kut.match_sessions later
  where later.season_id = session.season_id
    and later.status = 'published'
    and later.rating_rules_version = 2
    and (later.session_date, later.session_type, later.id)
        > (session.session_date, session.session_type, session.id)
) age
cross join lateral (
  select case age.value
           when 0 then 1.00
           when 1 then 0.75
           when 2 then 0.50
           when 3 then 0.25
           else 0.00
         end::numeric as value
) weight
left join lateral (
  select array_agg(category.title order by category.title) as titles
  from kut.kudos_categories category
  where category.id = any(result.qualified_category_ids)
) categories on true
where season.is_active
  and session.status = 'published'
  and session.rating_rules_version = 2;

comment on view kut.player_form_contributions is
  'ADR-074 / ADR-083: the per-session Form inputs behind a player''s current Form score (source = session), plus any comeback-from-injury input (source = comeback), with the session-age decay weight mirrored from kut._rebuild_season_core. Never joins session_kudos (nominator identity) or session_surveys (KB-013).';
