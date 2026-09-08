-- ADR-066 / KB-013: the Chronicle's finalized session results are a club-wide
-- read model, but they were only readable by that session's attendees.
--
-- kut.chronicle_session_reports ran with security_invoker=true, so the reader's
-- RLS applied to everything it touches. Its inner join to kut.session_surveys
-- hits "eligible members read surveys", which admits only kut.is_admin() or a
-- member holding a kut.session_survey_eligibility row for that session — i.e.
-- an attendee. Every member who missed the session therefore read zero rows and
-- the issue page rendered "Results finalized. No report results were recorded."
-- The same eligibility gate reached the results table itself: the
-- "members read finalized results" policy proved finalization with an exists()
-- over kut.session_surveys, and Postgres applies that table's own RLS inside a
-- policy expression, so the subquery could not see the survey either.
--
-- Two changes, no data change:
--   1. kut.is_survey_finalized(uuid) — a security-definer predicate — replaces
--      the policy's inline exists(), so "is this survey finalized?" stops
--      depending on whether the reader may see the survey row.
--   2. kut.chronicle_session_reports becomes security_invoker=false, matching
--      its sibling kut.chronicle_session_report_status (20260920090000), which
--      is why survey status and goal_total already reached every member while
--      the per-player results did not.
--
-- Nothing new is disclosed. effective_goals is already published club-wide as
-- chronicle_session_report_status.goal_total; recognized_categories only lists
-- categories two or more nominators agreed on, which is the Chronicle's
-- headline feature; goal_form, kudos_form and session_input are pure functions
-- of those two (the ADR-063 ladders); and submitted_reports / eligible_accounts
-- / attendee_count duplicate columns the status view already grants. Raw
-- ballots (kut.session_kudos) and provisional reports (kut.session_reports)
-- keep their own RLS and are never read here. The join to session_surveys with
-- status='finalized' is what keeps an open session out of the projection, and
-- it is now load-bearing rather than incidental — do not drop it.
--
-- Rollback:
--   create or replace view kut.chronicle_session_reports
--     with(security_invoker=true,security_barrier=true) as <body below>;
--   drop policy "members read finalized results" on kut.session_report_results;
--   create policy "members read finalized results" on kut.session_report_results
--     for select to authenticated using(exists(select 1 from kut.session_surveys s
--       where s.session_id=session_report_results.session_id and s.status='finalized'));
--   drop function kut.is_survey_finalized(uuid);

create or replace function kut.is_survey_finalized(p_session_id uuid)
returns boolean
language sql
stable
security definer
set search_path = kut, pg_catalog
as $$
  select exists (
    select 1 from kut.session_surveys survey
    where survey.session_id = p_session_id and survey.status = 'finalized'
  );
$$;
revoke execute on function kut.is_survey_finalized(uuid) from public, anon;
grant execute on function kut.is_survey_finalized(uuid) to authenticated, service_role;

drop policy "members read finalized results" on kut.session_report_results;
create policy "members read finalized results" on kut.session_report_results
for select to authenticated
using (kut.is_survey_finalized(session_report_results.session_id));

create or replace view kut.chronicle_session_reports
with(security_invoker=false,security_barrier=true) as
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
