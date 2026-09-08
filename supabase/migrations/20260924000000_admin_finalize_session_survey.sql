-- ADR-067: an admin can close a session's report window before its 24 hours are
-- up, instead of waiting for the deadline and the ADR-061 lazy fallback.
--
-- kut.admin_finalize_session_survey(uuid, text) is a thin, audited front door to
-- the existing kut._finalize_one_session: same scoring, same season rebuild,
-- same notifications. It adds nothing to the rating maths and changes no game
-- rule — the only thing that moves is *when* the window shuts. Everything
-- downstream already keys off kut.session_surveys.status, so finalizing early
-- closes submissions (submit_session_report rejects status <> 'open'), stops
-- kut.finalize_session_surveys from picking the row up again (it selects
-- status = 'open'), and flips chronicle_session_report_status.accepting_reports
-- to false without any further change.
--
-- closes_at is deliberately left alone: session_surveys carries
-- `check (closes_at = opened_at + interval '24 hours')`, so the published
-- deadline stays the published deadline and `finalized_at < closes_at` is what
-- identifies an early close. Two new nullable columns record who did it and
-- why; both stay null on the automatic path and on the re-finalization that
-- admin_correct_session_goals triggers, so "null" reads as "closed at its
-- deadline".
--
-- Members who had not submitted when an admin finalizes lose the ability to
-- submit and therefore the 50-coin completion reward. That is inherent to
-- closing the window and is surfaced in the admin UI as a count before the
-- action is taken; no reward is clawed back, and reward receipts already
-- written are untouched.
--
-- Rollback:
--   drop function kut.admin_finalize_session_survey(uuid, text);
--   alter table kut.session_surveys drop column finalized_reason, drop column finalized_by;

alter table kut.session_surveys
  add column finalized_by uuid references kut.profiles(id) on delete restrict,
  add column finalized_reason text
    check (finalized_reason is null or char_length(finalized_reason) between 3 and 500);

comment on column kut.session_surveys.finalized_by is
  'Admin who closed this survey before its deadline (ADR-067); null when it closed at closes_at.';

create function kut.admin_finalize_session_survey(p_session_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
declare
  v_survey record;
  v_attendees integer;
  v_eligible integer;
  v_submitted integer;
  v_ballots integer;
begin
  if not kut.is_admin() then
    raise exception 'admin access required' using errcode = '42501';
  end if;
  if char_length(trim(coalesce(p_reason, ''))) not between 3 and 500 then
    raise exception 'a reason of 3 to 500 characters is required' using errcode = '22023';
  end if;

  select survey.* into v_survey
  from kut.session_surveys survey
  join kut.match_sessions session on session.id = survey.session_id and session.status = 'published'
  where survey.session_id = p_session_id
  for update of survey;
  if not found then
    raise exception 'published session survey not found' using errcode = 'P0002';
  end if;
  if v_survey.status = 'cancelled' then
    raise exception 'this survey was cancelled' using errcode = 'P0001';
  end if;

  select
    (select count(*) from kut.attendance a where a.session_id = p_session_id),
    (select count(*) from kut.session_survey_eligibility e
      where e.session_id = p_session_id and e.user_id is not null),
    (select count(*) from kut.session_reports r
      where r.session_id = p_session_id and r.status = 'submitted'),
    -- The kudos quorum kut._finalize_one_session applies: a report only counts
    -- towards it once its author has actually nominated somebody.
    (select count(distinct r.player_id) from kut.session_reports r
      where r.session_id = p_session_id and r.status = 'submitted'
        and exists (select 1 from kut.session_kudos k
          where k.session_id = r.session_id and k.nominator_player_id = r.player_id))
  into v_attendees, v_eligible, v_submitted, v_ballots;

  if v_survey.status = 'finalized' then
    return jsonb_build_object(
      'session_id', p_session_id, 'already_finalized', true, 'attendees', v_attendees,
      'eligible_accounts', v_eligible, 'submitted_reports', v_submitted,
      'kudos_counted', v_ballots >= 3, 'closed_early', false
    );
  end if;

  -- Recorded before the call: _finalize_one_session updates status, finalized_at
  -- and revision on this row and would otherwise overwrite an update made after.
  update kut.session_surveys
  set finalized_by = auth.uid(), finalized_reason = trim(p_reason)
  where session_id = p_session_id;

  perform kut._finalize_one_session(p_session_id);

  return jsonb_build_object(
    'session_id', p_session_id, 'already_finalized', false, 'attendees', v_attendees,
    'eligible_accounts', v_eligible, 'submitted_reports', v_submitted,
    'kudos_counted', v_ballots >= 3, 'closed_early', now() < v_survey.closes_at
  );
end;
$$;

revoke all on function kut.admin_finalize_session_survey(uuid, text) from public, anon;
grant execute on function kut.admin_finalize_session_survey(uuid, text) to authenticated, service_role;
