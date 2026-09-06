-- Slice E read-model completion: only finalized aggregates reach Chronicle.
create or replace view kut.chronicle_weeks
with(security_invoker=true,security_barrier=true) as
select date_trunc('week',session.session_date)::date week_start,
  date_trunc('week',session.session_date)::date+6 week_end,
  count(distinct session.id)::integer session_count,count(attendance.player_id)::integer appearance_count,
  count(distinct attendance.player_id)::integer attendee_count,
  coalesce(sum(case when session.rating_rules_version=1 then attendance.goals else result.effective_goals end),0)::integer goal_count
from kut.match_sessions session left join kut.attendance attendance on attendance.session_id=session.id
left join kut.session_report_results result on result.session_id=session.id and result.player_id=attendance.player_id
where session.status='published' group by date_trunc('week',session.session_date)::date;

create view kut.chronicle_session_reports
with(security_invoker=true,security_barrier=true) as
select result.session_id,result.player_id,player.display_name,player.slug,result.effective_goals,
  result.goal_form,result.kudos_form,result.session_input,
  coalesce((select array_agg(category.title order by category.title) from kut.kudos_categories category where category.id=any(result.qualified_category_ids)),'{}') recognized_categories,
  (select count(*) from kut.session_reports report where report.session_id=result.session_id and report.status='submitted')::integer submitted_reports,
  (select count(*) from kut.session_survey_eligibility eligibility where eligibility.session_id=result.session_id and eligibility.user_id is not null)::integer eligible_accounts,
  (select count(*) from kut.attendance attendance where attendance.session_id=result.session_id)::integer attendee_count
from kut.session_report_results result join kut.players player on player.id=result.player_id
join kut.session_surveys survey on survey.session_id=result.session_id and survey.status='finalized';
revoke all on kut.chronicle_session_reports from public,anon;
grant select on kut.chronicle_session_reports to authenticated,service_role;
