-- Chronicle deadline state is database-authoritative. This prevents UI/server
-- clock drift and keeps the React render pure.
create or replace view kut.chronicle_session_report_status
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
  ),0)::integer as goal_total,
  (survey.status='open' and survey.closes_at>now()) as accepting_reports
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
