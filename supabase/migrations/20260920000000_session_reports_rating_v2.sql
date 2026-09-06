-- Slice E / ADR-059: versioned self-reports, once-only completion rewards,
-- audited goal correction, deterministic finalization, and mixed v1/v2 ratings.

alter table kut.match_sessions add column rating_rules_version integer not null default 1
  check (rating_rules_version in (1, 2));

create table kut.season_rating_rules (
  season_id uuid primary key references kut.seasons(id) on delete cascade,
  v2_starts_week date not null,
  created_at timestamptz not null default now()
);
insert into kut.season_rating_rules(season_id, v2_starts_week)
select season.id,
  coalesce((select max(date_trunc('week', s.session_date)::date) + 7 from kut.match_sessions s where s.season_id = season.id and s.status = 'published'),
           date_trunc('week', current_date)::date + 7)
from kut.seasons season;

create table kut.kudos_categories (
  id uuid primary key,
  slug text not null unique,
  title text not null,
  description text not null
);
insert into kut.kudos_categories(id, slug, title, description) values
('10000000-0000-4000-8000-000000000001','team-player','Team Player','Puts the team first and helps everyone play.'),
('10000000-0000-4000-8000-000000000002','engine','Engine','Keeps running and lifts the tempo.'),
('10000000-0000-4000-8000-000000000003','playmaker','Playmaker','Creates chances and connects the play.'),
('10000000-0000-4000-8000-000000000004','the-wall','The Wall','Stops attacks and protects the team.'),
('10000000-0000-4000-8000-000000000005','difference-maker','Difference Maker','Changes the session with a decisive contribution.'),
('10000000-0000-4000-8000-000000000006','great-vibes','Great Vibes','Makes the session better for everyone.'),
('10000000-0000-4000-8000-000000000007','level-up','Level Up','Shows clear progress and keeps improving.');

create table kut.session_surveys (
  session_id uuid primary key references kut.match_sessions(id) on delete restrict,
  status text not null default 'open' check (status in ('open','finalized','cancelled')),
  opened_at timestamptz not null,
  closes_at timestamptz not null,
  category_ids uuid[] not null check (cardinality(category_ids) = 3),
  selection_seed uuid not null,
  rules_version integer not null default 2 check (rules_version = 2),
  reward_amount bigint not null default 50 check (reward_amount = 50),
  finalized_at timestamptz,
  revision integer not null default 0,
  check (closes_at = opened_at + interval '24 hours'),
  check ((status = 'finalized') = (finalized_at is not null))
);

create table kut.session_survey_eligibility (
  session_id uuid not null references kut.session_surveys(session_id) on delete cascade,
  player_id uuid not null references kut.players(id) on delete restrict,
  user_id uuid references kut.profiles(id) on delete set null,
  captured_at timestamptz not null default now(),
  primary key(session_id, player_id),
  unique(session_id, user_id)
);

create table kut.session_reports (
  session_id uuid not null references kut.session_surveys(session_id) on delete restrict,
  player_id uuid not null references kut.players(id) on delete restrict,
  submitted_by uuid not null references kut.profiles(id) on delete restrict,
  goals integer check (goals between 0 and 99),
  status text not null check (status in ('draft','submitted')),
  explicit_skips uuid[] not null default '{}',
  submitted_at timestamptz,
  updated_at timestamptz not null default now(),
  revision integer not null default 1,
  primary key(session_id, player_id),
  check ((status = 'submitted') = (submitted_at is not null))
);

create function kut.normalize_session_report_status()
returns trigger language plpgsql set search_path=kut,pg_catalog as $$
begin
  if new.status='submit' then new.status:='submitted'; end if;
  return new;
end $$;
create trigger session_reports_normalize_status before insert or update of status on kut.session_reports
for each row execute function kut.normalize_session_report_status();

create table kut.session_kudos (
  session_id uuid not null,
  nominator_player_id uuid not null,
  category_id uuid not null references kut.kudos_categories(id) on delete restrict,
  recipient_player_id uuid not null references kut.players(id) on delete restrict,
  created_at timestamptz not null default now(),
  primary key(session_id, nominator_player_id, category_id),
  unique(session_id, nominator_player_id, recipient_player_id),
  foreign key(session_id, nominator_player_id) references kut.session_reports(session_id, player_id) on delete cascade,
  check (nominator_player_id <> recipient_player_id)
);

create table kut.session_report_requests (
  user_id uuid not null references kut.profiles(id) on delete restrict,
  idempotency_key uuid not null,
  session_id uuid not null references kut.session_surveys(session_id) on delete restrict,
  result jsonb not null,
  created_at timestamptz not null default now(),
  primary key(user_id, idempotency_key)
);

create table kut.session_report_rewards (
  session_id uuid not null,
  player_id uuid not null,
  user_id uuid not null references kut.profiles(id) on delete restrict,
  amount bigint not null check (amount = 50),
  ledger_id uuid not null unique references kut.wallet_ledger(id) on delete restrict deferrable initially deferred,
  created_at timestamptz not null default now(),
  primary key(session_id, player_id),
  foreign key(session_id, player_id) references kut.session_reports(session_id, player_id) on delete restrict
);

create table kut.session_goal_overrides (
  session_id uuid not null references kut.session_surveys(session_id) on delete restrict,
  player_id uuid not null references kut.players(id) on delete restrict,
  goals integer check (goals between 0 and 99),
  reason text not null check (char_length(trim(reason)) between 3 and 500),
  corrected_by uuid not null references kut.profiles(id) on delete restrict,
  corrected_at timestamptz not null default now(),
  primary key(session_id, player_id)
);

create table kut.session_goal_override_audit (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references kut.session_surveys(session_id) on delete restrict,
  player_id uuid not null references kut.players(id) on delete restrict,
  previous_goals integer,
  previous_had_override boolean not null,
  corrected_goals integer,
  corrected_has_override boolean not null,
  reason text not null,
  corrected_by uuid not null references kut.profiles(id) on delete restrict,
  corrected_at timestamptz not null default now()
);

create table kut.session_report_results (
  session_id uuid not null references kut.session_surveys(session_id) on delete restrict,
  player_id uuid not null references kut.players(id) on delete restrict,
  effective_goals integer,
  goal_form numeric(4,2) not null,
  kudos_form numeric(4,2) not null,
  session_input numeric(4,2) not null check (session_input between 0 and 3),
  qualified_category_ids uuid[] not null default '{}',
  computed_at timestamptz not null default now(),
  primary key(session_id, player_id)
);

create table kut.session_survey_jobs (
  id bigint generated always as identity primary key,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  processed_count integer not null default 0,
  error_text text
);

do $$ declare v_name text; begin
  select conname into v_name from pg_constraint where conrelid='kut.wallet_ledger'::regclass and contype='c' and pg_get_constraintdef(oid) ilike '%admin_self_grant%' and pg_get_constraintdef(oid) ilike '%reason%';
  if v_name is null then raise exception 'wallet ledger reason constraint not found'; end if;
  execute format('alter table kut.wallet_ledger drop constraint %I', v_name);
end $$;
alter table kut.wallet_ledger add constraint wallet_ledger_reason_check check (reason in (
  'starter','attendance_reward','pack_purchase','discard','market_sale','market_buy','market_tax','admin_correction','admin_grant','admin_reset','bibs_bonus','trade_escrow','trade_unescrow','trade_sale','admin_self_grant','session_report_reward'
));

do $$ declare v_name text; begin
  select conname into v_name from pg_constraint where conrelid='kut.user_notifications'::regclass and contype='c' and pg_get_constraintdef(oid) ilike '%trade_response%' and pg_get_constraintdef(oid) ilike '%event_type%';
  if v_name is null then raise exception 'notification type constraint not found'; end if;
  execute format('alter table kut.user_notifications drop constraint %I', v_name);
end $$;
alter table kut.user_notifications add constraint user_notifications_event_type_check check (event_type in (
  'market_sale','market_purchase','attendance_reward','pack_opened','admin_notice','bibs_bonus','trade_offer','trade_response','session_report','session_results','report_correction'
));

create function kut._version_and_open_session_survey()
returns trigger language plpgsql security definer set search_path=kut,pg_catalog as $$
declare v_categories uuid[]; v_seed uuid := gen_random_uuid();
begin
  if new.status = 'published' and old.status <> 'published' then
    new.rating_rules_version := case when date_trunc('week',new.session_date)::date >=
      (select v2_starts_week from kut.season_rating_rules where season_id=new.season_id) then 2 else 1 end;
  end if;
  return new;
end $$;
create trigger match_sessions_rating_version before update of status on kut.match_sessions
for each row execute function kut._version_and_open_session_survey();

create function kut._open_session_survey()
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
    select e.user_id,'session_report','Goals & kudos','Your session report is open for 24 hours. Complete it to receive 50 KUT Coins.','match_session',new.id
    from kut.session_survey_eligibility e where e.session_id=new.id and e.user_id is not null
    on conflict(user_id,event_type,reference_type,reference_id) where reference_type is not null and reference_id is not null do nothing;
  elsif new.status='cancelled' then
    update kut.session_surveys set status='cancelled', finalized_at=null where session_id=new.id;
  end if;
  return new;
end $$;
create trigger match_sessions_open_survey after update of status on kut.match_sessions
for each row execute function kut._open_session_survey();

alter table kut.kudos_categories enable row level security;
alter table kut.session_surveys enable row level security;
alter table kut.session_survey_eligibility enable row level security;
alter table kut.session_reports enable row level security;
alter table kut.session_kudos enable row level security;
alter table kut.session_report_requests enable row level security;
alter table kut.session_report_rewards enable row level security;
alter table kut.session_goal_overrides enable row level security;
alter table kut.session_goal_override_audit enable row level security;
alter table kut.session_report_results enable row level security;
alter table kut.session_survey_jobs enable row level security;
create policy "members read kudos categories" on kut.kudos_categories for select to authenticated using(true);
create policy "eligible members read surveys" on kut.session_surveys for select to authenticated using(kut.is_admin() or exists(select 1 from kut.session_survey_eligibility e where e.session_id=session_surveys.session_id and e.user_id=auth.uid()));
create policy "members read own eligibility" on kut.session_survey_eligibility for select to authenticated using(user_id=auth.uid() or kut.is_admin());
create policy "members read own reports" on kut.session_reports for select to authenticated using(submitted_by=auth.uid() or kut.is_admin());
create policy "members read own ballots" on kut.session_kudos for select to authenticated using(kut.is_admin() or exists(select 1 from kut.session_reports r where r.session_id=session_kudos.session_id and r.player_id=session_kudos.nominator_player_id and r.submitted_by=auth.uid()));
create policy "members read own report requests" on kut.session_report_requests for select to authenticated using(user_id=auth.uid() or kut.is_admin());
create policy "members read own report rewards" on kut.session_report_rewards for select to authenticated using(user_id=auth.uid() or kut.is_admin());
create policy "admins read goal overrides" on kut.session_goal_overrides for select to authenticated using(kut.is_admin());
create policy "admins read goal override audit" on kut.session_goal_override_audit for select to authenticated using(kut.is_admin());
create policy "members read finalized results" on kut.session_report_results for select to authenticated using(exists(select 1 from kut.session_surveys s where s.session_id=session_report_results.session_id and s.status='finalized'));
create policy "admins read survey jobs" on kut.session_survey_jobs for select to authenticated using(kut.is_admin());
grant select on kut.kudos_categories,kut.session_surveys,kut.session_survey_eligibility,kut.session_reports,kut.session_kudos,kut.session_report_requests,kut.session_report_rewards,kut.session_goal_overrides,kut.session_goal_override_audit,kut.session_report_results,kut.session_survey_jobs to authenticated,service_role;
revoke insert,update,delete on kut.session_surveys,kut.session_survey_eligibility,kut.session_reports,kut.session_kudos,kut.session_report_requests,kut.session_report_rewards,kut.session_goal_overrides,kut.session_goal_override_audit,kut.session_report_results from authenticated;

create function kut.submit_session_report(
  p_session_id uuid, p_goals integer, p_nominations jsonb,
  p_expected_revision integer, p_idempotency_key uuid, p_intent text default 'submit'
) returns jsonb language plpgsql security definer set search_path=kut,pg_catalog as $$
declare
  v_user uuid:=auth.uid(); v_player uuid; v_survey record; v_report record; v_cat uuid;
  v_recipient uuid; v_skips uuid[]:='{}'; v_result jsonb; v_ledger uuid:=gen_random_uuid();
  v_rewarded boolean:=false; v_revision integer; v_present integer; v_distinct integer;
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
    elsif p_intent='submit' then raise exception 'every category needs a nominee or Skip' using errcode='22023'; end if;
  end loop;
  select count(*),count(distinct value) into v_present,v_distinct from jsonb_each_text(p_nominations) where value is not null;
  if v_present<>v_distinct then raise exception 'each teammate can be nominated only once' using errcode='22023'; end if;
  if p_intent='submit' and p_goals is null then raise exception 'goals must be explicitly reported' using errcode='22023'; end if;
  insert into kut.session_reports(session_id,player_id,submitted_by,goals,status,explicit_skips,submitted_at,revision)
  values(p_session_id,v_player,v_user,p_goals,p_intent, v_skips,case when p_intent='submit' then now() end,v_revision+1)
  on conflict(session_id,player_id) do update set goals=excluded.goals,status=excluded.status,explicit_skips=excluded.explicit_skips,submitted_at=case when excluded.status='submitted' then coalesce(session_reports.submitted_at,now()) end,updated_at=now(),revision=session_reports.revision+1;
  delete from kut.session_kudos where session_id=p_session_id and nominator_player_id=v_player;
  for v_cat in select unnest(v_survey.category_ids) loop
    if p_nominations ? v_cat::text and jsonb_typeof(p_nominations->v_cat::text)='string' then
      insert into kut.session_kudos(session_id,nominator_player_id,category_id,recipient_player_id)
      values(p_session_id,v_player,v_cat,(p_nominations->>v_cat::text)::uuid);
    end if;
  end loop;
  if p_intent='submit' then
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
  v_result:=jsonb_build_object('conflict',false,'revision',v_revision+1,'status',p_intent,'rewarded',v_rewarded,'reward_already_received',exists(select 1 from kut.session_report_rewards where session_id=p_session_id and player_id=v_player));
  insert into kut.session_report_requests(user_id,idempotency_key,session_id,result) values(v_user,p_idempotency_key,p_session_id,v_result);
  return v_result;
end $$;

revoke all on function kut.submit_session_report(uuid,integer,jsonb,integer,uuid,text) from public,anon;
grant execute on function kut.submit_session_report(uuid,integer,jsonb,integer,uuid,text) to authenticated,service_role;

create function kut._finalize_one_session(p_session_id uuid)
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
    v_kudos_form:=least(1.5,cardinality(v_qualified)*0.5);
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

create function kut.finalize_session_surveys(p_batch_limit integer default 20)
returns integer language plpgsql security definer set search_path=kut,pg_catalog as $$
declare v_row record; v_count integer:=0; v_job bigint;
begin
  if coalesce(auth.role(),'')<>'service_role' then raise exception 'service role required' using errcode='42501'; end if;
  if p_batch_limit not between 1 and 100 then raise exception 'batch limit must be 1..100' using errcode='22023'; end if;
  insert into kut.session_survey_jobs default values returning id into v_job;
  for v_row in select session_id from kut.session_surveys where status='open' and closes_at<=now() order by closes_at for update skip locked limit p_batch_limit loop
    begin perform kut._finalize_one_session(v_row.session_id); v_count:=v_count+1;
    exception when others then update kut.session_survey_jobs set error_text=concat_ws(E'\n',error_text,format('%s: %s',v_row.session_id,sqlerrm)) where id=v_job; end;
  end loop;
  update kut.session_survey_jobs set finished_at=now(),processed_count=v_count where id=v_job;
  return v_count;
end $$;
revoke all on function kut.finalize_session_surveys(integer) from public,anon,authenticated;
grant execute on function kut.finalize_session_surveys(integer) to service_role;

create function kut.admin_correct_session_goals(p_session_id uuid,p_player_id uuid,p_goals integer,p_remove_override boolean,p_reason text)
returns jsonb language plpgsql security definer set search_path=kut,pg_catalog as $$
declare v_previous integer; v_had boolean; v_status text; v_user uuid;
begin
  if not kut.is_admin() then raise exception 'admin access required' using errcode='42501'; end if;
  if char_length(trim(coalesce(p_reason,''))) not between 3 and 500 or (not p_remove_override and (p_goals is null or p_goals<0 or p_goals>99)) then raise exception 'valid goals and reason are required' using errcode='22023'; end if;
  select s.status into v_status from kut.session_surveys s join kut.match_sessions m on m.id=s.session_id where s.session_id=p_session_id and m.status='published' for update of s;
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
    values(v_user,'report_correction','Reported goals corrected','An administrator corrected the effective goal total and recorded a reason. Your form completion and reward are unchanged.','match_session',p_session_id)
    on conflict(user_id,event_type,reference_type,reference_id) where reference_type is not null and reference_id is not null do nothing; end if;
  return jsonb_build_object('session_id',p_session_id,'player_id',p_player_id,'has_override',not p_remove_override,'goals',case when p_remove_override then null else p_goals end);
end $$;
revoke all on function kut.admin_correct_session_goals(uuid,uuid,integer,boolean,text) from public,anon;
grant execute on function kut.admin_correct_session_goals(uuid,uuid,integer,boolean,text) to authenticated,service_role;

create view kut.my_session_reports with(security_invoker=true,security_barrier=true) as
select survey.session_id,session.session_date,session.session_type,survey.status as survey_status,survey.closes_at,survey.category_ids,survey.reward_amount,
  eligibility.player_id,report.goals,report.status as report_status,coalesce(report.revision,0) as revision,report.explicit_skips,report.submitted_at,
  (reward.session_id is not null) as reward_received
from kut.session_survey_eligibility eligibility join kut.session_surveys survey on survey.session_id=eligibility.session_id
join kut.match_sessions session on session.id=survey.session_id left join kut.session_reports report on report.session_id=survey.session_id and report.player_id=eligibility.player_id
left join kut.session_report_rewards reward on reward.session_id=survey.session_id and reward.player_id=eligibility.player_id
where eligibility.user_id=auth.uid();

create view kut.admin_session_report_roster with(security_invoker=true,security_barrier=true) as
select a.session_id,a.player_id,p.display_name,profile.id as user_id,report.status as report_status,report.submitted_at,report.goals as reported_goals,
  override.goals as override_goals,(override.session_id is not null) as has_override,(reward.session_id is not null) as reward_paid
from kut.attendance a join kut.players p on p.id=a.player_id left join kut.profiles profile on profile.player_id=a.player_id and not profile.is_disabled
left join kut.session_reports report on report.session_id=a.session_id and report.player_id=a.player_id
left join kut.session_goal_overrides override on override.session_id=a.session_id and override.player_id=a.player_id
left join kut.session_report_rewards reward on reward.session_id=a.session_id and reward.player_id=a.player_id
where kut.is_admin();
revoke all on kut.my_session_reports,kut.admin_session_report_roster from public,anon;
grant select on kut.my_session_reports,kut.admin_session_report_roster to authenticated,service_role;

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
  for v_player in select id,archetype from kut.players loop
    v_activity:=0; v_legacy:=0; v_form:=0; v_goals:=0; v_last_week:=null;
    for v_week in select date_trunc('week',session_date)::date week_start
      from kut.match_sessions where season_id=p_season_id and status='published'
      group by 1 order by 1 loop
      v_last_week:=v_week.week_start;
      select count(*) into v_appearances from kut.attendance a join kut.match_sessions s on s.id=a.session_id
      where a.player_id=v_player.id and s.season_id=p_season_id and s.status='published' and date_trunc('week',s.session_date)::date=v_week.week_start;
      v_activity:=least(100,greatest(0,v_activity*.90+case when v_appearances>=1 then 14 else 0 end+case when v_appearances>=2 then 3 else 0 end));
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
          from kut.session_report_results r join kut.match_sessions s on s.id=r.session_id
          where r.player_id=v_player.id and s.season_id=p_season_id and s.status='published' and s.rating_rules_version=2 and s.session_date<(v_week.week_start+7)
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
