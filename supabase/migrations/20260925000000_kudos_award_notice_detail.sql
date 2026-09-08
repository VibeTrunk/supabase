-- ADR-069: the kudos-awarded notice names the categories and attributes the OVR
-- move to this session's goals and kudos.
--
-- ADR-063 introduced `kudos_awarded` with a deliberately vague body: "Teammates
-- recognized you with kudos this session. Your card rating rose +N OVR this
-- week." Members could not tell *what* they had been recognised for, and the
-- rating line read as though the week's whole movement came from kudos alone.
--
-- The body now:
--   1. Names every category the player was recognised in, in the order the
--      session's ballot presented them, joined as "A, B and C".
--   2. Attributes the movement to what actually produced it — this session's
--      reported goals *and* the kudos — naming the goal count when there is
--      one, and saying only "these kudos" when the player scored none.
--
-- It still never names a nominator, still goes only to players with at least one
-- recognised category, and is still omitted entirely when the movement is <= 0.
-- Kudos are recognised at >= 2 nominators in a category with a >= 3 ballot
-- quorum, unchanged.
--
-- Additive and text-only: `create or replace` of one function body. No table,
-- constraint, grant, scoring rule or rating maths changes, and no data change —
-- notices already written keep their old wording, since re-finalizing a session
-- hits the existing `on conflict do nothing`.
--
-- Rollback: drop function kut._join_names(text[]); then re-run the
--   `create or replace function kut._finalize_one_session` block from
--   20260922000000_kudos_cap_two_and_award_notice.sql.

-- "Engine" / "Engine and Playmaker" / "Engine, Playmaker and The Wall".
create function kut._join_names(p_names text[])
returns text language sql immutable set search_path=pg_catalog as $$
  select case
    when p_names is null or cardinality(p_names) = 0 then null
    when cardinality(p_names) = 1 then p_names[1]
    else array_to_string(p_names[1:cardinality(p_names)-1], ', ')
         || ' and ' || p_names[cardinality(p_names)]
  end
$$;
revoke all on function kut._join_names(text[]) from public,anon;
grant execute on function kut._join_names(text[]) to service_role;

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
    'Teammates recognized you for ' || kut._join_names(named.titles) || ' this session.'
    || case when moved.delta > 0 then
         format(' %s lifted your card rating +%s OVR this week.',
           case when coalesce(rr.effective_goals,0) > 0
                then format('Your %s and these kudos',
                     case when rr.effective_goals=1 then '1 goal' else rr.effective_goals||' goals' end)
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
