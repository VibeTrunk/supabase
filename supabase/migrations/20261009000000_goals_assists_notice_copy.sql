-- ADR-101: from the football week beginning 2026-09-28 the one number a member
-- reports per session is goals and assists combined ("G+A"), not goals alone.
--
-- Copy only. The stored integer, its columns and RPC parameters (`goals`,
-- `p_goals`, `reported_goals`, `effective_goals`, `goal_form`) keep their names,
-- and the count feeds the unchanged scoring: 0 / 1 / 1.25 / 1.5 Form for
-- 0 / 1 / 2 / 3+, kudos 0 / 1 / 1.5 / 2, the 3.5 per-session cap, the Form cap
-- of 8, the Live OVR ceiling of 83 and the recent-week SHO modifier
-- (least(8, 2 * count)). A combined 4 therefore earns exactly what 4 goals did,
-- SHO +8 included. Goals and assists are never stored apart.
--
-- What changes is the wording of the notices SQL writes, and only for a session
-- dated on or after 2026-09-28; an earlier session keeps its goals wording:
--
--   session_report    (_open_session_survey)         title "Goals & kudos"
--                                                     -> "Goals + Assists & kudos"
--   session_results   (_finalize_one_session)        "Reported goals and ..."
--                                                     -> "Reported G+A and ..."
--   kudos_awarded     (_finalize_one_session)        "Your 2 goals and these kudos"
--                                                     -> "Your 4 G+A and these kudos"
--   report_correction (admin_correct_session_goals)  "Reported goals corrected",
--                                                     "the effective goal total"
--                                                     -> "Reported G+A corrected",
--                                                     "the effective G+A total"
--
-- Each function body is its latest definition verbatim
-- (_finalize_one_session from 20260925000000; admin_correct_session_goals and
-- _open_session_survey from 20260920000000, never redefined since), changed only
-- by a date lookup and a wording branch. Locking, qualification, scoring,
-- rebuild, idempotency (`on conflict ... do nothing`), security definer and
-- search_path are untouched. `create or replace` keeps each function's owner,
-- privileges and trigger binding; the grants below restate the existing ones.
--
-- No table, column, constraint, view, RLS policy, privilege or data change.
-- Notices already written keep their wording: nothing is backfilled or
-- relabelled, and a re-finalization still hits `on conflict do nothing`.
--
-- Tier: additive (ADR-032) — function bodies only, no DML.
--
-- Rollback: re-run the `create or replace function kut._finalize_one_session`
--   block from 20260925000000_kudos_award_notice_detail.sql and the
--   `kut._open_session_survey` and `kut.admin_correct_session_goals` blocks from
--   20260920000000_session_reports_rating_v2.sql (as `create or replace`), then
--   drop function kut._uses_combined_count(date).

-- The one place SQL states the cutover. Its TypeScript twin is
-- GOALS_ASSISTS_CUTOVER in src/game/reported-count.ts; both sides are pinned by
-- tests at 2026-09-27 / 2026-09-28.
create function kut._uses_combined_count(p_session_date date)
returns boolean language sql immutable set search_path=pg_catalog as $$
  select p_session_date >= date '2026-09-28'
$$;
revoke all on function kut._uses_combined_count(date) from public,anon;
grant execute on function kut._uses_combined_count(date) to service_role;

-- 1. The report-open notice (the match_sessions_open_survey trigger) ------------
create or replace function kut._open_session_survey()
returns trigger language plpgsql security definer set search_path=kut,pg_catalog as $$
declare v_categories uuid[]; v_seed uuid := gen_random_uuid();
begin
  if new.status='published' and new.rating_rules_version=2 and (old.status is distinct from 'published') then
    select array_agg(id order by usage_count, tie_break) into v_categories from (
      select category.id,
        (select count(*) from kut.session_surveys survey where category.id=any(survey.category_ids)
          and exists(select 1 from kut.match_sessions prior where prior.id=survey.session_id and prior.season_id=new.season_id)) as usage_count,
        md5(v_seed::text || category.id::text) as tie_break
      from kut.kudos_categories category order by usage_count, tie_break limit 3
    ) picked;
    insert into kut.session_surveys(session_id,opened_at,closes_at,category_ids,selection_seed)
    values(new.id,new.published_at,new.published_at+interval '24 hours',v_categories,v_seed)
    on conflict(session_id) do nothing;
    insert into kut.session_survey_eligibility(session_id,player_id,user_id)
    select new.id,a.player_id,p.id from kut.attendance a
    left join kut.profiles p on p.player_id=a.player_id and not p.is_disabled
    where a.session_id=new.id on conflict do nothing;
    insert into kut.user_notifications(user_id,event_type,title,body,reference_type,reference_id)
    select e.user_id,'session_report',
      case when kut._uses_combined_count(new.session_date) then 'Goals + Assists & kudos' else 'Goals & kudos' end,'Your session report is open for 24 hours. Complete it to receive 50 KUT Coins.','match_session',new.id
    from kut.session_survey_eligibility e where e.session_id=new.id and e.user_id is not null
    on conflict(user_id,event_type,reference_type,reference_id) where reference_type is not null and reference_id is not null do nothing;
  elsif new.status='cancelled' then
    update kut.session_surveys set status='cancelled', finalized_at=null where session_id=new.id;
  end if;
  return new;
end $$;

-- 2. Finalization: the session_results and kudos_awarded notices ---------------
create or replace function kut._finalize_one_session(p_session_id uuid)
returns void language plpgsql security definer set search_path=kut,pg_catalog as $$
declare v_survey record; v_player uuid; v_goals integer; v_qualified uuid[]; v_turnout integer; v_goal_form numeric; v_kudos_form numeric; v_season uuid; v_pre_ovr jsonb; v_session_date date; v_combined boolean;
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
    v_kudos_form:=case cardinality(v_qualified) when 0 then 0 when 1 then 1 when 2 then 1.5 else 2 end;
    insert into kut.session_report_results(session_id,player_id,effective_goals,goal_form,kudos_form,session_input,qualified_category_ids)
    values(p_session_id,v_player,v_goals,v_goal_form,v_kudos_form,least(3.5,v_goal_form+v_kudos_form),v_qualified);
  end loop;
  update kut.session_surveys set status='finalized',finalized_at=now(),revision=revision+1 where session_id=p_session_id;
  -- ADR-101: the session date (read with the season) picks the notices' wording.
  select season_id,session_date into v_season,v_session_date from kut.match_sessions where id=p_session_id;
  v_combined:=kut._uses_combined_count(v_session_date);
  select coalesce(jsonb_object_agg(player_id::text,live_ovr),'{}'::jsonb) into v_pre_ovr
  from kut.player_season_state where season_id=v_season;
  perform kut._rebuild_season_core(v_season);
  insert into kut.user_notifications(user_id,event_type,title,body,reference_type,reference_id)
  select e.user_id,'session_results','Session report ready',
    case when v_combined then 'Reported G+A and recognized kudos are now in the Chronicle.'
         else 'Reported goals and recognized kudos are now in the Chronicle.' end,'match_session',p_session_id
  from kut.session_survey_eligibility e where e.session_id=p_session_id and e.user_id is not null
  on conflict(user_id,event_type,reference_type,reference_id) where reference_type is not null and reference_id is not null do nothing;
  insert into kut.user_notifications(user_id,event_type,title,body,reference_type,reference_id)
  select e.user_id,'kudos_awarded','Kudos awarded',
    'Teammates recognized you for ' || kut._join_names(named.titles) || ' this session.'
    || case when moved.delta > 0 then
         format(' %s lifted your card rating +%s OVR this week.',
           case when coalesce(rr.effective_goals,0) > 0
                then format('Your %s and these kudos',
                     case when v_combined then rr.effective_goals||' G+A'
                          when rr.effective_goals=1 then '1 goal' else rr.effective_goals||' goals' end)
                else 'These kudos' end,
           moved.delta)
       else '' end,
    'match_session',p_session_id
  from kut.session_report_results rr
  join kut.session_survey_eligibility e on e.session_id=rr.session_id and e.player_id=rr.player_id and e.user_id is not null
  join kut.player_season_state post on post.player_id=rr.player_id and post.season_id=v_season
  cross join lateral (
    -- Ballot order, so the notice lists the categories the way the member saw them.
    select array_agg(c.title order by array_position(v_survey.category_ids,c.id)) as titles
    from kut.kudos_categories c where c.id = any(rr.qualified_category_ids)
  ) named
  cross join lateral (
    select post.live_ovr - coalesce((v_pre_ovr->>rr.player_id::text)::integer, post.live_ovr) as delta
  ) moved
  where rr.session_id=p_session_id and cardinality(rr.qualified_category_ids)>0
  on conflict(user_id,event_type,reference_type,reference_id) where reference_type is not null and reference_id is not null do nothing;
end $$;
revoke execute on function kut._finalize_one_session(uuid) from public,anon,authenticated;

-- 3. The admin correction notice -----------------------------------------------
create or replace function kut.admin_correct_session_goals(p_session_id uuid,p_player_id uuid,p_goals integer,p_remove_override boolean,p_reason text)
returns jsonb language plpgsql security definer set search_path=kut,pg_catalog as $$
declare v_previous integer; v_had boolean; v_status text; v_user uuid; v_session_date date;
begin
  if not kut.is_admin() then raise exception 'admin access required' using errcode='42501'; end if;
  if char_length(trim(coalesce(p_reason,''))) not between 3 and 500 or (not p_remove_override and (p_goals is null or p_goals<0 or p_goals>99)) then raise exception 'valid goals and reason are required' using errcode='22023'; end if;
  select s.status,m.session_date into v_status,v_session_date from kut.session_surveys s join kut.match_sessions m on m.id=s.session_id where s.session_id=p_session_id and m.status='published' for update of s;
  if not found or not exists(select 1 from kut.attendance where session_id=p_session_id and player_id=p_player_id) then raise exception 'published attendee not found' using errcode='P0002'; end if;
  select goals,true into v_previous,v_had from kut.session_goal_overrides where session_id=p_session_id and player_id=p_player_id;
  v_had:=coalesce(v_had,false);
  if p_remove_override then delete from kut.session_goal_overrides where session_id=p_session_id and player_id=p_player_id;
  else insert into kut.session_goal_overrides(session_id,player_id,goals,reason,corrected_by) values(p_session_id,p_player_id,p_goals,trim(p_reason),auth.uid())
    on conflict(session_id,player_id) do update set goals=excluded.goals,reason=excluded.reason,corrected_by=excluded.corrected_by,corrected_at=now(); end if;
  insert into kut.session_goal_override_audit(session_id,player_id,previous_goals,previous_had_override,corrected_goals,corrected_has_override,reason,corrected_by)
  values(p_session_id,p_player_id,v_previous,v_had,case when p_remove_override then null else p_goals end,not p_remove_override,trim(p_reason),auth.uid());
  if v_status='finalized' then perform kut._finalize_one_session(p_session_id); end if;
  select id into v_user from kut.profiles where player_id=p_player_id and not is_disabled;
  if v_user is not null then insert into kut.user_notifications(user_id,event_type,title,body,reference_type,reference_id)
    values(v_user,'report_correction',
      case when kut._uses_combined_count(v_session_date) then 'Reported G+A corrected' else 'Reported goals corrected' end,
      case when kut._uses_combined_count(v_session_date)
           then 'An administrator corrected the effective G+A total and recorded a reason. Your form completion and reward are unchanged.'
           else 'An administrator corrected the effective goal total and recorded a reason. Your form completion and reward are unchanged.' end,
      'match_session',p_session_id)
    on conflict(user_id,event_type,reference_type,reference_id) where reference_type is not null and reference_id is not null do nothing; end if;
  return jsonb_build_object('session_id',p_session_id,'player_id',p_player_id,'has_override',not p_remove_override,'goals',case when p_remove_override then null else p_goals end);
end $$;
revoke all on function kut.admin_correct_session_goals(uuid,uuid,integer,boolean,text) from public,anon;
grant execute on function kut.admin_correct_session_goals(uuid,uuid,integer,boolean,text) to authenticated,service_role;
