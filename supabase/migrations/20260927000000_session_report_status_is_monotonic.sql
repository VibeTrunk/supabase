-- KB-020 / ADR-078 -- a submitted session report can never regress to draft.
--
-- Tier: data-changing. The DDL is one `create or replace function`; the DML is
-- a scoped repair of rows that already regressed. Needs a fresh cold-verified
-- backup before the hosted push, like ADR-063.
--
-- The defect. `kut.submit_session_report`'s upsert wrote `status=excluded.status`
-- unconditionally and collapsed `submitted_at` to null whenever the new status
-- was not 'submitted'. The report form rendered "Save draft" even once a report
-- was submitted, so a member could press it and silently move their own report
-- back to draft -- while `kut.session_report_rewards`, written once on the
-- original submit and never deleted, kept the 50-coin reward. The admin roster
-- joins the two independently and showed exactly that: "Draft - Reward paid".
--
-- Why it is not cosmetic. `kut._finalize_one_session` scores only
-- `r.status='submitted'` rows, and uses that same filter for the `v_turnout>=3`
-- gate. A report left in this state at finalization drops that member's goals
-- and kudos from scoring, and if turnout falls below three it wipes kudos
-- recognition for *everyone* in that session -- while their `session_kudos`
-- rows still count toward recipients' `count(distinct nominator_player_id)>=2`.
--
-- The fix is one derived local, `v_intent`, resolved from the stored row before
-- any validation runs. Deliberately not a guard inside the `on conflict do
-- update`: that would hold `status='submitted'` while letting the row be
-- rewritten under the weaker draft validation, so an already-submitted report
-- could end up submitted with a null goal count or an incomplete ballot.
-- Promoting the intent first means an edit to a submitted report must satisfy
-- the same completeness rules that earned it. The `on conflict` clause itself
-- is therefore unchanged: with `v_intent='submit'` the BEFORE trigger
-- normalises `excluded.status` to 'submitted', and `submitted_at` resolves to
-- `coalesce(session_reports.submitted_at, now())`, preserving the original
-- timestamp. The table's `check ((status='submitted') = (submitted_at is not
-- null))` holds in all four transitions. The reward insert is still
-- `on conflict do nothing`, so nothing is ever paid twice, and the
-- idempotency-key replay path is untouched.
--
-- Deliberately NOT replaying already-finalized sessions. `_finalize_one_session`
-- is re-runnable -- `kut.admin_correct_session_goals` calls it exactly that way
-- -- but replaying it here would move live OVR for real members retroactively,
-- push `finalized_at` forward and disturb the ADR-067 reading of
-- `finalized_at < closes_at`. Authorized decision, 2026-09-22: the repair stops
-- at the row. For any session already finalized with a regressed report, that
-- member's goals and kudos stay out of that week's scoring, and a session whose
-- turnout had fallen below three keeps its lost kudos recognition. A later
-- `admin_correct_session_goals` on such a session re-scores it correctly.
--
-- Rollback:
--   1. Re-emit the pre-KB-020 body of kut.submit_session_report verbatim from
--      20260920000000_session_reports_rating_v2.sql:242-308, as
--      `create or replace function` (the only differences are the `v_intent`
--      local, the five uses of it, and the comment above it).
--   2. The backfill is NOT reversible: nothing records which rows were draft
--      before it ran. A row repaired here cannot be told apart afterwards from
--      one that was simply submitted normally.
--   Grants are unchanged by `create or replace`; the re-assertion below is
--   defensive only.

create or replace function kut.submit_session_report(
  p_session_id uuid, p_goals integer, p_nominations jsonb,
  p_expected_revision integer, p_idempotency_key uuid, p_intent text default 'submit'
) returns jsonb language plpgsql security definer set search_path=kut,pg_catalog as $$
declare
  v_user uuid:=auth.uid(); v_player uuid; v_survey record; v_report record; v_cat uuid;
  v_recipient uuid; v_skips uuid[]:='{}'; v_result jsonb; v_ledger uuid:=gen_random_uuid();
  v_rewarded boolean:=false; v_revision integer; v_present integer; v_distinct integer; v_intent text;
begin
  if v_user is null then raise exception 'authentication required' using errcode='42501'; end if;
  if p_idempotency_key is null or p_intent not in ('draft','submit') or p_expected_revision < 0
    or (p_goals is not null and (p_goals<0 or p_goals>99)) or jsonb_typeof(coalesce(p_nominations,'{}'))<>'object'
    then raise exception 'invalid report input' using errcode='22023'; end if;
  select result into v_result from kut.session_report_requests where user_id=v_user and idempotency_key=p_idempotency_key;
  if found then return v_result; end if;
  select * into v_survey from kut.session_surveys where session_id=p_session_id for update;
  if not found then raise exception 'session survey not found' using errcode='P0002'; end if;
  if v_survey.status<>'open' or now()>=v_survey.closes_at then raise exception 'reports are closed' using errcode='P0001'; end if;
  select profile.player_id into v_player from kut.profiles profile join kut.attendance a on a.player_id=profile.player_id and a.session_id=p_session_id where profile.id=v_user and not profile.is_disabled;
  if v_player is null then raise exception 'linked attendee not found' using errcode='42501'; end if;
  insert into kut.session_survey_eligibility(session_id,player_id,user_id) values(p_session_id,v_player,v_user)
  on conflict(session_id,player_id) do update set user_id=excluded.user_id where session_survey_eligibility.user_id is null;
  select * into v_report from kut.session_reports where session_id=p_session_id and player_id=v_player for update;
  v_revision:=case when found then v_report.revision else 0 end;
  -- KB-020 / ADR-078: a submitted report never goes back to draft. The
  -- promotion happens here, above the validation below, so an edit to a
  -- submitted report is held to the same completeness rules that earned it
  -- rather than being rewritten under the weaker draft rules.
  v_intent:=case when v_report.status='submitted' then 'submit' else p_intent end;
  if v_revision<>p_expected_revision then
    return jsonb_build_object('conflict',true,'revision',v_revision,'rewarded',exists(select 1 from kut.session_report_rewards where session_id=p_session_id and player_id=v_player));
  end if;
  for v_cat in select unnest(v_survey.category_ids) loop
    if p_nominations ? v_cat::text then
      if jsonb_typeof(p_nominations->v_cat::text)='null' then v_skips:=array_append(v_skips,v_cat);
      elsif jsonb_typeof(p_nominations->v_cat::text)='string' then
        begin v_recipient:=(p_nominations->>v_cat::text)::uuid; exception when invalid_text_representation then raise exception 'invalid nominee' using errcode='22023'; end;
        if v_recipient=v_player or not exists(select 1 from kut.attendance where session_id=p_session_id and player_id=v_recipient) then raise exception 'nominee must be another attendee' using errcode='22023'; end if;
      else raise exception 'invalid nominee' using errcode='22023'; end if;
    elsif v_intent='submit' then raise exception 'every category needs a nominee or Skip' using errcode='22023'; end if;
  end loop;
  select count(*),count(distinct value) into v_present,v_distinct from jsonb_each_text(p_nominations) where value is not null;
  if v_present<>v_distinct then raise exception 'each teammate can be nominated only once' using errcode='22023'; end if;
  if v_intent='submit' and p_goals is null then raise exception 'goals must be explicitly reported' using errcode='22023'; end if;
  insert into kut.session_reports(session_id,player_id,submitted_by,goals,status,explicit_skips,submitted_at,revision)
  values(p_session_id,v_player,v_user,p_goals,v_intent, v_skips,case when v_intent='submit' then now() end,v_revision+1)
  on conflict(session_id,player_id) do update set goals=excluded.goals,status=excluded.status,explicit_skips=excluded.explicit_skips,submitted_at=case when excluded.status='submitted' then coalesce(session_reports.submitted_at,now()) end,updated_at=now(),revision=session_reports.revision+1;
  delete from kut.session_kudos where session_id=p_session_id and nominator_player_id=v_player;
  for v_cat in select unnest(v_survey.category_ids) loop
    if p_nominations ? v_cat::text and jsonb_typeof(p_nominations->v_cat::text)='string' then
      insert into kut.session_kudos(session_id,nominator_player_id,category_id,recipient_player_id)
      values(p_session_id,v_player,v_cat,(p_nominations->>v_cat::text)::uuid);
    end if;
  end loop;
  if v_intent='submit' then
    insert into kut.session_report_rewards(session_id,player_id,user_id,amount,ledger_id)
    values(p_session_id,v_player,v_user,v_survey.reward_amount,v_ledger) on conflict do nothing;
    if found then
      v_rewarded:=true;
      insert into kut.wallets(user_id,balance) values(v_user,0) on conflict do nothing;
      insert into kut.wallet_ledger(id,user_id,amount,reason,reference_type,reference_id,idempotency_key)
      values(v_ledger,v_user,v_survey.reward_amount,'session_report_reward','match_session',p_session_id,'report:'||p_session_id::text||':'||v_player::text);
      update kut.wallets set balance=balance+v_survey.reward_amount,updated_at=now() where user_id=v_user;
    end if;
  end if;
  v_result:=jsonb_build_object('conflict',false,'revision',v_revision+1,'status',v_intent,'rewarded',v_rewarded,'reward_already_received',exists(select 1 from kut.session_report_rewards where session_id=p_session_id and player_id=v_player));
  insert into kut.session_report_requests(user_id,idempotency_key,session_id,result) values(v_user,p_idempotency_key,p_session_id,v_result);
  return v_result;
end $$;

revoke all on function kut.submit_session_report(uuid,integer,jsonb,integer,uuid,text) from public,anon;
grant execute on function kut.submit_session_report(uuid,integer,jsonb,integer,uuid,text) to authenticated,service_role;

-- Repair the rows that already regressed. A kut.session_report_rewards row is
-- written only by a real submit and is never deleted, so its presence beside a
-- 'draft' status is an exact victim predicate -- no other path produces it.
-- submitted_at is recovered from updated_at, the closest surviving evidence of
-- when the report was last written; the table's check constraint requires it to
-- be non-null whenever status is 'submitted'.
update kut.session_reports r
   set status='submitted',
       submitted_at=coalesce(r.submitted_at,r.updated_at,now()),
       updated_at=now()
 where r.status='draft'
   and exists (select 1 from kut.session_report_rewards w
                where w.session_id=r.session_id and w.player_id=r.player_id);
