-- ADR-063: raise the per-session kudos Form ceiling and tell recognised players.
--   1. Kudos Form ladder 0 / 1 / 1.5 / 2 for 0 / 1 / 2 / 3 recognised categories
--      (was 0 / 1 / 1.25 / 1.5).
--   2. Combined per-session Form input capped at 3.5 (was 3), so a hat-trick
--      scorer can still bank full kudos. Goals still cap at 1.5; the v2 Form
--      ceiling stays 8.
--   3. New `kudos_awarded` notification, sent at finalization to every player
--      with >= 1 recognised category. It never names a nominator; it reports the
--      player's OVR movement from finalising this session (goals + kudos), or no
--      number when the movement is <= 0.
--
-- Data-changing: re-scores existing kut.session_report_results derived rows and
-- deterministically replays affected seasons. Raw reports, ballots, rewards,
-- transactions and survey audit timestamps are untouched. Historical finalized
-- sessions do NOT emit `kudos_awarded` (the backfill does not run
-- _finalize_one_session).

-- 1. Widen the combined per-session Form input cap 3 -> 3.5.
do $$ declare v_name text; begin
  select conname into v_name from pg_constraint
  where conrelid = 'kut.session_report_results'::regclass and contype = 'c'
    and pg_get_constraintdef(oid) ilike '%session_input%';
  if v_name is null then raise exception 'session_input check constraint not found'; end if;
  execute format('alter table kut.session_report_results drop constraint %I', v_name);
end $$;
alter table kut.session_report_results
  add constraint session_report_results_session_input_check
  check (session_input between 0 and 3.5);

-- 2. Allow the `kudos_awarded` notification type.
do $$ declare v_name text; begin
  select conname into v_name from pg_constraint
  where conrelid = 'kut.user_notifications'::regclass and contype = 'c'
    and pg_get_constraintdef(oid) ilike '%event_type%' and pg_get_constraintdef(oid) ilike '%session_results%';
  if v_name is null then raise exception 'notification event_type constraint not found'; end if;
  execute format('alter table kut.user_notifications drop constraint %I', v_name);
end $$;
alter table kut.user_notifications add constraint user_notifications_event_type_check check (event_type in (
  'market_sale','market_purchase','attendance_reward','pack_opened','admin_notice','bibs_bonus','trade_offer','trade_response','session_report','session_results','report_correction','kudos_awarded'
));

-- 3. Finalizer: new kudos ladder, 3.5 combined cap, and the kudos-awarded notice.
create or replace function kut._finalize_one_session(p_session_id uuid)
returns void language plpgsql security definer set search_path=kut,pg_catalog as $$
declare v_survey record; v_player uuid; v_goals integer; v_qualified uuid[]; v_turnout integer; v_goal_form numeric; v_kudos_form numeric; v_season uuid; v_pre_ovr jsonb;
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
  select season_id into v_season from kut.match_sessions where id=p_session_id;
  select coalesce(jsonb_object_agg(player_id::text,live_ovr),'{}'::jsonb) into v_pre_ovr
  from kut.player_season_state where season_id=v_season;
  perform kut._rebuild_season_core(v_season);
  insert into kut.user_notifications(user_id,event_type,title,body,reference_type,reference_id)
  select e.user_id,'session_results','Session report ready','Reported goals and recognized kudos are now in the Chronicle.','match_session',p_session_id
  from kut.session_survey_eligibility e where e.session_id=p_session_id and e.user_id is not null
  on conflict(user_id,event_type,reference_type,reference_id) where reference_type is not null and reference_id is not null do nothing;
  insert into kut.user_notifications(user_id,event_type,title,body,reference_type,reference_id)
  select e.user_id,'kudos_awarded','Kudos awarded',
    'Teammates recognized you with kudos this session'
    || case when post.live_ovr - coalesce((v_pre_ovr->>rr.player_id::text)::integer, post.live_ovr) > 0
         then format('. Your card rating rose +%s OVR this week.',
              post.live_ovr - coalesce((v_pre_ovr->>rr.player_id::text)::integer, post.live_ovr))
         else '.' end,
    'match_session',p_session_id
  from kut.session_report_results rr
  join kut.session_survey_eligibility e on e.session_id=rr.session_id and e.player_id=rr.player_id and e.user_id is not null
  join kut.player_season_state post on post.player_id=rr.player_id and post.season_id=v_season
  where rr.session_id=p_session_id and cardinality(rr.qualified_category_ids)>0
  on conflict(user_id,event_type,reference_type,reference_id) where reference_type is not null and reference_id is not null do nothing;
end $$;
revoke execute on function kut._finalize_one_session(uuid) from public,anon,authenticated;

-- 4. Re-score already-finalized derived rows to the new ladder / cap, then
--    deterministically replay each affected season. No notifications are sent.
update kut.session_report_results
set kudos_form=case cardinality(qualified_category_ids) when 0 then 0 when 1 then 1 when 2 then 1.5 else 2 end,
    session_input=least(3.5,goal_form+case cardinality(qualified_category_ids) when 0 then 0 when 1 then 1 when 2 then 1.5 else 2 end),
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
