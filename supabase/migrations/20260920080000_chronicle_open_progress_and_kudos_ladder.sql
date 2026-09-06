-- Slice E feedback follow-up:
-- 1. Chronicle exposes aggregate open-survey progress without exposing ballots
--    or individual provisional reports.
-- 2. The first recognized kudos category is a meaningful +1 Form, while
--    diminishing returns preserve the existing +1.5 per-session kudos cap.

create or replace function kut._finalize_one_session(p_session_id uuid)
returns void language plpgsql security definer set search_path=kut,pg_catalog as $$
declare v_survey record; v_player uuid; v_goals integer; v_qualified uuid[]; v_turnout integer; v_goal_form numeric; v_kudos_form numeric; v_season uuid;
begin
  select * into v_survey from kut.session_surveys where session_id=p_session_id for update;
  if not found or v_survey.status='cancelled' then return; end if;
  select count(distinct r.player_id) into v_turnout from kut.session_reports r
  where r.session_id=p_session_id and r.status='submitted' and exists(select 1 from kut.session_kudos k where k.session_id=r.session_id and k.nominator_player_id=r.player_id);
  delete from kut.session_report_results where session_id=p_session_id;
  for v_player in select player_id from kut.attendance where session_id=p_session_id loop
    select case when o.session_id is not null then o.goals else r.goals end into v_goals
    from (select 1) anchor left join kut.session_reports r on r.session_id=p_session_id and r.player_id=v_player and r.status='submitted'
    left join kut.session_goal_overrides o on o.session_id=p_session_id and o.player_id=v_player;
    if v_turnout>=3 then
      select coalesce(array_agg(category_id order by category_id),'{}') into v_qualified from (
        select category_id from kut.session_kudos where session_id=p_session_id and recipient_player_id=v_player
        group by category_id having count(distinct nominator_player_id)>=2
      ) q;
    else v_qualified:='{}'; end if;
    v_goal_form:=case when coalesce(v_goals,0)=0 then 0 when v_goals=1 then 1 when v_goals=2 then 1.25 else 1.5 end;
    v_kudos_form:=case cardinality(v_qualified) when 0 then 0 when 1 then 1 when 2 then 1.25 else 1.5 end;
    insert into kut.session_report_results(session_id,player_id,effective_goals,goal_form,kudos_form,session_input,qualified_category_ids)
    values(p_session_id,v_player,v_goals,v_goal_form,v_kudos_form,least(3,v_goal_form+v_kudos_form),v_qualified);
  end loop;
  update kut.session_surveys set status='finalized',finalized_at=now(),revision=revision+1 where session_id=p_session_id;
  select season_id into v_season from kut.match_sessions where id=p_session_id;
  perform kut._rebuild_season_core(v_season);
  insert into kut.user_notifications(user_id,event_type,title,body,reference_type,reference_id)
  select e.user_id,'session_results','Session report ready','Reported goals and recognized kudos are now in the Chronicle.','match_session',p_session_id
  from kut.session_survey_eligibility e where e.session_id=p_session_id and e.user_id is not null
  on conflict(user_id,event_type,reference_type,reference_id) where reference_type is not null and reference_id is not null do nothing;
end $$;
revoke execute on function kut._finalize_one_session(uuid) from public,anon,authenticated;

-- This security-definer projection deliberately publishes aggregates only.
-- It never exposes individual provisional goals, nominees, or vote counts.
create view kut.chronicle_session_report_status
with(security_invoker=false,security_barrier=true) as
select survey.session_id,
  survey.status as survey_status,
  survey.closes_at,
  count(attendance.player_id)::integer as attendee_count,
  count(report.player_id) filter(where report.status='submitted')::integer as submitted_reports,
  count(eligibility.user_id)::integer as eligible_accounts,
  coalesce(sum(
    case
      when survey.status='finalized' then result.effective_goals
      when override.session_id is not null then override.goals
      when report.status='submitted' then report.goals
      else null
    end
  ),0)::integer as goal_total
from kut.session_surveys survey
join kut.match_sessions session on session.id=survey.session_id and session.status='published'
left join kut.attendance attendance on attendance.session_id=survey.session_id
left join kut.session_survey_eligibility eligibility on eligibility.session_id=attendance.session_id and eligibility.player_id=attendance.player_id
left join kut.session_reports report on report.session_id=attendance.session_id and report.player_id=attendance.player_id
left join kut.session_goal_overrides override on override.session_id=attendance.session_id and override.player_id=attendance.player_id
left join kut.session_report_results result on result.session_id=attendance.session_id and result.player_id=attendance.player_id
group by survey.session_id,survey.status,survey.closes_at;

revoke all on kut.chronicle_session_report_status from public,anon;
grant select on kut.chronicle_session_report_status to authenticated,service_role;

create or replace view kut.chronicle_weeks
with(security_invoker=true,security_barrier=true) as
with session_totals as (
  select session.id,
    date_trunc('week',session.session_date)::date as week_start,
    session.rating_rules_version,
    (select count(*) from kut.attendance attendance where attendance.session_id=session.id)::integer as appearance_count,
    case
      when session.rating_rules_version=1 then coalesce((select sum(attendance.goals) from kut.attendance attendance where attendance.session_id=session.id),0)
      else coalesce(reporting.goal_total,0)
    end::integer as goal_count
  from kut.match_sessions session
  left join kut.chronicle_session_report_status reporting on reporting.session_id=session.id
  where session.status='published'
)
select totals.week_start,
  totals.week_start+6 as week_end,
  count(*)::integer as session_count,
  sum(totals.appearance_count)::integer as appearance_count,
  (select count(distinct attendance.player_id)
   from kut.attendance attendance
   join kut.match_sessions session on session.id=attendance.session_id
   where session.status='published'
     and date_trunc('week',session.session_date)::date=totals.week_start)::integer as attendee_count,
  sum(totals.goal_count)::integer as goal_count
from session_totals totals
group by totals.week_start;

-- Re-score already-finalized derived rows without changing report receipts,
-- survey audit timestamps, or raw ballots, then replay each affected season.
update kut.session_report_results
set kudos_form=case cardinality(qualified_category_ids) when 0 then 0 when 1 then 1 when 2 then 1.25 else 1.5 end,
    session_input=least(3,goal_form+case cardinality(qualified_category_ids) when 0 then 0 when 1 then 1 when 2 then 1.25 else 1.5 end),
    computed_at=now();

do $$ declare v_season uuid; begin
  for v_season in
    select distinct session.season_id
    from kut.session_report_results result
    join kut.match_sessions session on session.id=result.session_id
  loop
    perform kut._rebuild_season_core(v_season);
  end loop;
end $$;
