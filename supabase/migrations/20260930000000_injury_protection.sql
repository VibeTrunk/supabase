-- ADR-082: injury mode. A long-term injured Player's card stops decaying for
-- every football week he checks in, and each check-in pays a 100 KUT Coin
-- stipend.
--
-- Activity decays x0.90 every football week a Player misses (BUILD_SPEC §11),
-- so a full-activity 75 OVR card falls to ~53 after two months out. That hurts
-- the injured Player and every member who owns his card. This migration adds:
--
--   1. kut.injury_periods   -- an admin puts a Player (with an account) into
--                              injury mode from a date. Admin-only table; the
--                              optional note may hold medical detail and is
--                              never exposed to members.
--   2. kut.injury_check_ins -- one row per (Player, football week) he checked
--                              in for. This is the ONLY fact the rating engine
--                              reads, so the rebuild stays deterministic
--                              (Part L #16).
--   3. kut._rebuild_season_core -- a week with a check-in and zero appearances
--                              carries Activity over unchanged instead of
--                              decaying it. Form is untouched: v2 Form ages by
--                              club sessions, so it keeps fading on its own.
--   4. kut.injury_check_in / kut.my_injury_status -- the member side. A week is
--                              open for a check-in when it is the current or
--                              the previous ISO week (Europe/Amsterdam), holds a
--                              published session in the active season, the
--                              Player made no appearance in it, and it is not
--                              before the injury date.
--   5. kut.admin_start_injury / kut.admin_end_injury -- the admin side.
--   6. kut.injured_players  -- club-wide projection behind the card badge,
--                              gated on kut.is_active_member() (ADR-079).
--   7. A notice to each injured account holder when a week's first session is
--                              published: "Rehab check-in is open".
--
-- "Active injury" is DERIVED, not stored: a period is active while it is open
-- and the Player has no attendance at a published session dated strictly
-- after started_on. Returning to play therefore ends it with no trigger, and an
-- attendance correction re-derives it. Strictly after, because a Player is
-- often injured *during* a session he attended, and the admin enters that date.
--
-- No backdating (owner decision, 2026-09-23): protection starts at the first
-- check-in. There is no admin path to protect past weeks.
--
-- Tier: data-changing (docs/OPERATIONS.md) -- a new wallet_ledger reason and a
-- rating-engine change. No existing row is written, and the rebuild output is
-- byte-identical until the first check-in row exists.
--
-- Rollback:
--   drop trigger match_sessions_injury_check_in_notice on kut.match_sessions;
--   drop function kut._notify_injury_check_in_open();
--   drop view kut.injured_players;
--   drop function kut.injury_check_in(date);
--   drop function kut.my_injury_status();
--   drop function kut.admin_end_injury(uuid, text);
--   drop function kut.admin_start_injury(uuid, date, text);
--   drop function kut._injury_checkable_week(uuid, uuid, date);
--   drop function kut._active_injury_period(uuid);
--   re-run the `create or replace function kut._rebuild_season_core` block from
--     20260920000000_session_reports_rating_v2.sql:406-464;
--   drop table kut.injury_check_ins; drop table kut.injury_periods;
--   restore both check constraints from the lists below minus 'injury_stipend'
--     and 'injury_check_in' (only after deleting any rows that use them).

-- 1. Tables ------------------------------------------------------------------

create table kut.injury_periods (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references kut.players(id) on delete restrict,
  started_on date not null,
  note text check (note is null or char_length(note) between 1 and 200),
  started_by uuid references kut.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  ended_on date,
  -- Null when the period was closed automatically (see admin_start_injury).
  ended_by uuid references kut.profiles(id) on delete set null,
  end_reason text check (end_reason is null or char_length(end_reason) between 3 and 200),
  check ((ended_on is null) = (end_reason is null)),
  check (ended_on is null or ended_on >= started_on)
);
create unique index injury_periods_one_open_idx on kut.injury_periods (player_id) where ended_on is null;

create table kut.injury_check_ins (
  player_id uuid not null references kut.players(id) on delete restrict,
  -- ISO Monday of the protected football week.
  week_start date not null check (extract(isodow from week_start) = 1),
  period_id uuid not null references kut.injury_periods(id) on delete restrict,
  user_id uuid not null references kut.profiles(id) on delete cascade,
  amount integer not null check (amount > 0),
  ledger_id uuid not null unique,
  created_at timestamptz not null default now(),
  -- The natural key is the idempotency guard (the kut.bibs_rewards pattern):
  -- a week is protected, and paid, at most once per Player (Part L #24).
  primary key (player_id, week_start)
);
create index injury_check_ins_period_idx on kut.injury_check_ins (period_id);

alter table kut.injury_periods enable row level security;
alter table kut.injury_check_ins enable row level security;
create policy "admins read injury periods" on kut.injury_periods
  for select to authenticated using (kut.is_admin());
create policy "members read own injury check-ins" on kut.injury_check_ins
  for select to authenticated using (user_id = auth.uid() or kut.is_admin());
revoke all on kut.injury_periods, kut.injury_check_ins from public, anon;
grant select on kut.injury_periods, kut.injury_check_ins to authenticated, service_role;
revoke insert, update, delete on kut.injury_periods, kut.injury_check_ins from authenticated;

-- 2. Constraint widening -------------------------------------------------------
-- Lists copied from 20260920000000:160-162 (ledger) and 20260922000000:38-40
-- (notifications), each with one value appended.

do $$ declare v_name text; begin
  select conname into v_name from pg_constraint
  where conrelid = 'kut.wallet_ledger'::regclass and contype = 'c'
    and pg_get_constraintdef(oid) ilike '%reason%' and pg_get_constraintdef(oid) ilike '%session_report_reward%';
  if v_name is null then raise exception 'wallet ledger reason constraint not found'; end if;
  execute format('alter table kut.wallet_ledger drop constraint %I', v_name);
end $$;
alter table kut.wallet_ledger add constraint wallet_ledger_reason_check check (reason in (
  'starter','attendance_reward','pack_purchase','discard','market_sale','market_buy','market_tax','admin_correction','admin_grant','admin_reset','bibs_bonus','trade_escrow','trade_unescrow','trade_sale','admin_self_grant','session_report_reward','injury_stipend'
));

do $$ declare v_name text; begin
  select conname into v_name from pg_constraint
  where conrelid = 'kut.user_notifications'::regclass and contype = 'c'
    and pg_get_constraintdef(oid) ilike '%event_type%' and pg_get_constraintdef(oid) ilike '%kudos_awarded%';
  if v_name is null then raise exception 'notification event_type constraint not found'; end if;
  execute format('alter table kut.user_notifications drop constraint %I', v_name);
end $$;
alter table kut.user_notifications add constraint user_notifications_event_type_check check (event_type in (
  'market_sale','market_purchase','attendance_reward','pack_opened','admin_notice','bibs_bonus','trade_offer','trade_response','session_report','session_results','report_correction','kudos_awarded','injury_check_in'
));

-- 3. Shared rules ---------------------------------------------------------------

-- The one definition of "actively injured". Returns the open period's id, or
-- null when there is none or the Player has played since it started.
create function kut._active_injury_period(p_player_id uuid)
returns uuid language sql stable security definer set search_path = kut, pg_catalog as $$
  select period.id
  from kut.injury_periods period
  where period.player_id = p_player_id
    and period.ended_on is null
    and not exists (
      select 1 from kut.attendance a
      join kut.match_sessions s on s.id = a.session_id
      where a.player_id = period.player_id
        and s.status = 'published'
        and s.session_date > period.started_on
    );
$$;
revoke all on function kut._active_injury_period(uuid) from public, anon, authenticated;
grant execute on function kut._active_injury_period(uuid) to service_role;

-- True when p_week_start may be checked in for, as of p_today. Caller has
-- already established that p_period_id is p_player_id's active period.
create function kut._injury_checkable_week(p_player_id uuid, p_period_id uuid, p_week_start date)
returns boolean language sql stable security definer set search_path = kut, pg_catalog as $$
  select p_week_start is not null
    and extract(isodow from p_week_start) = 1
    and p_week_start in (
      date_trunc('week', (now() at time zone 'Europe/Amsterdam')::date)::date,
      date_trunc('week', (now() at time zone 'Europe/Amsterdam')::date)::date - 7
    )
    and p_week_start >= (select date_trunc('week', started_on)::date from kut.injury_periods where id = p_period_id)
    -- A football week of the active season (BUILD_SPEC §9).
    and exists (
      select 1 from kut.match_sessions s join kut.seasons season on season.id = s.season_id
      where season.is_active and s.status = 'published'
        and date_trunc('week', s.session_date)::date = p_week_start
    )
    -- A week he played is scored normally and pays the attendance reward.
    and not exists (
      select 1 from kut.attendance a join kut.match_sessions s on s.id = a.session_id
      where a.player_id = p_player_id and s.status = 'published'
        and date_trunc('week', s.session_date)::date = p_week_start
    )
    and not exists (
      select 1 from kut.injury_check_ins c where c.player_id = p_player_id and c.week_start = p_week_start
    );
$$;
revoke all on function kut._injury_checkable_week(uuid, uuid, date) from public, anon, authenticated;
grant execute on function kut._injury_checkable_week(uuid, uuid, date) to service_role;

-- 4. Rating engine ----------------------------------------------------------------
-- Body verbatim from 20260920000000_session_reports_rating_v2.sql:406-463 except
-- the Activity line inside the week loop, now wrapped in the protected-week test.

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
      -- ADR-082: an injury check-in protects a week he did not play. Activity
      -- carries over unchanged, as in a week with no TFH session at all.
      if v_appearances=0 and exists(select 1 from kut.injury_check_ins c where c.player_id=v_player.id and c.week_start=v_week.week_start) then
        null;
      else
        v_activity:=least(100,greatest(0,v_activity*.90+case when v_appearances>=1 then 14 else 0 end+case when v_appearances>=2 then 3 else 0 end));
      end if;
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

-- 5. Admin RPCs -------------------------------------------------------------------

create function kut.admin_start_injury(p_player_id uuid, p_started_on date, p_note text default null)
returns jsonb language plpgsql security definer set search_path = kut, pg_catalog as $$
declare
  v_note text := nullif(trim(coalesce(p_note, '')), '');
  v_today date := (now() at time zone 'Europe/Amsterdam')::date;
  v_user uuid; v_name text; v_period uuid;
begin
  if not kut.is_admin() then raise exception 'admin access required' using errcode = '42501'; end if;
  if p_player_id is null or p_started_on is null or p_started_on > v_today
    or (v_note is not null and char_length(v_note) > 200) then
    raise exception 'a player, an injury date no later than today and a note of at most 200 characters are required' using errcode = '22023';
  end if;
  select player.display_name, profile.id into v_name, v_user
  from kut.players player
  left join kut.profiles profile on profile.player_id = player.id and not profile.is_disabled
  where player.id = p_player_id;
  if v_name is null then raise exception 'player not found' using errcode = 'P0002'; end if;
  -- The check-in is a member action, so a Player without an account could
  -- never be protected or paid. Out of scope for v1 (ADR-082).
  if v_user is null then raise exception 'player has no active account' using errcode = 'P0001'; end if;
  -- The stipend is a faucet; an admin never switches it on for themselves.
  if v_user = auth.uid() then raise exception 'you cannot put your own player in injury mode' using errcode = '42501'; end if;
  if exists (
    select 1 from kut.attendance a join kut.match_sessions s on s.id = a.session_id
    where a.player_id = p_player_id and s.status = 'published' and s.session_date > p_started_on
  ) then
    raise exception 'player has played since that date' using errcode = 'P0001';
  end if;

  -- A previous period whose Player has since returned is still open in the
  -- table (the active state is derived). Close it so the new one can start.
  update kut.injury_periods period
  set ended_on = greatest(period.started_on, least(v_today, (
        select min(s.session_date) from kut.attendance a join kut.match_sessions s on s.id = a.session_id
        where a.player_id = period.player_id and s.status = 'published' and s.session_date > period.started_on))),
      end_reason = 'returned to play'
  where period.player_id = p_player_id and period.ended_on is null
    and kut._active_injury_period(p_player_id) is distinct from period.id;

  begin
    insert into kut.injury_periods (player_id, started_on, note, started_by)
    values (p_player_id, p_started_on, v_note, auth.uid())
    returning id into v_period;
  exception when unique_violation then
    raise exception 'player is already in injury mode' using errcode = 'P0001';
  end;

  insert into kut.user_notifications (user_id, event_type, title, body, reference_type, reference_id)
  values (
    v_user, 'admin_notice', 'Injury mode on',
    'Get well soon! While you are out, check in from Home once every football week you sit out: you receive 100 KUT Coins and your card rating is protected for that week.',
    'injury_period', v_period
  )
  on conflict (user_id, event_type, reference_type, reference_id)
    where reference_type is not null and reference_id is not null do nothing;

  return jsonb_build_object('period_id', v_period, 'player_id', p_player_id, 'display_name', v_name, 'started_on', p_started_on);
end $$;
revoke all on function kut.admin_start_injury(uuid, date, text) from public, anon;
grant execute on function kut.admin_start_injury(uuid, date, text) to authenticated, service_role;

create function kut.admin_end_injury(p_player_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = kut, pg_catalog as $$
declare
  v_reason text := trim(coalesce(p_reason, ''));
  v_today date := (now() at time zone 'Europe/Amsterdam')::date;
  v_period record; v_user uuid; v_name text;
begin
  if not kut.is_admin() then raise exception 'admin access required' using errcode = '42501'; end if;
  if char_length(v_reason) not between 3 and 200 then
    raise exception 'a reason of 3-200 characters is required' using errcode = '22023';
  end if;
  select * into v_period from kut.injury_periods
  where player_id = p_player_id and ended_on is null for update;
  if not found then raise exception 'player is not in injury mode' using errcode = 'P0002'; end if;

  -- Protected weeks stay protected: ending a period never rewrites history, so
  -- no rebuild is needed here.
  update kut.injury_periods
  set ended_on = greatest(started_on, v_today), ended_by = auth.uid(), end_reason = v_reason
  where id = v_period.id;

  select player.display_name, profile.id into v_name, v_user
  from kut.players player
  left join kut.profiles profile on profile.player_id = player.id and not profile.is_disabled
  where player.id = p_player_id;
  if v_user is not null then
    insert into kut.user_notifications (user_id, event_type, title, body, reference_type, reference_id)
    values (v_user, 'admin_notice', 'Injury mode ended',
      format('An admin ended injury mode for your player. Reason: %s', v_reason),
      'injury_period_end', v_period.id)
    on conflict (user_id, event_type, reference_type, reference_id)
      where reference_type is not null and reference_id is not null do nothing;
  end if;

  return jsonb_build_object('period_id', v_period.id, 'player_id', p_player_id, 'display_name', v_name);
end $$;
revoke all on function kut.admin_end_injury(uuid, text) from public, anon;
grant execute on function kut.admin_end_injury(uuid, text) to authenticated, service_role;

-- 6. Member RPCs ------------------------------------------------------------------

create function kut.my_injury_status()
returns jsonb language plpgsql stable security definer set search_path = kut, pg_catalog as $$
declare
  v_player uuid; v_period record; v_this_week date := date_trunc('week', (now() at time zone 'Europe/Amsterdam')::date)::date;
  v_checkable date;
begin
  select player_id into v_player from kut.profiles where id = auth.uid() and not is_disabled;
  if v_player is null then return jsonb_build_object('injured', false); end if;
  select * into v_period from kut.injury_periods where id = kut._active_injury_period(v_player);
  if not found then return jsonb_build_object('injured', false); end if;

  -- Oldest open week first: last week's window closes sooner.
  select week into v_checkable
  from (values (v_this_week - 7), (v_this_week)) weeks(week)
  where kut._injury_checkable_week(v_player, v_period.id, week)
  order by week limit 1;

  return jsonb_build_object(
    'injured', true,
    'started_on', v_period.started_on,
    'checkable_week_start', v_checkable,
    'checked_in_this_week', exists(select 1 from kut.injury_check_ins where player_id = v_player and week_start = v_this_week),
    'protected_weeks', (select count(*) from kut.injury_check_ins where period_id = v_period.id),
    'stipend', 100
  );
end $$;
revoke all on function kut.my_injury_status() from public, anon;
grant execute on function kut.my_injury_status() to authenticated, service_role;

create function kut.injury_check_in(p_week_start date)
returns jsonb language plpgsql security definer set search_path = kut, pg_catalog as $$
declare
  -- Mirrored by ECONOMY.injuryStipend in src/game/economy.ts and BUILD_SPEC Part 145.
  v_amount constant integer := 100;
  v_user uuid := auth.uid(); v_player uuid; v_period uuid; v_season uuid;
  v_ledger uuid := gen_random_uuid(); v_balance bigint;
begin
  if v_user is null then raise exception 'authentication required' using errcode = '42501'; end if;
  select player_id into v_player from kut.profiles where id = v_user and not is_disabled;
  if v_player is null then raise exception 'linked player not found' using errcode = '42501'; end if;
  v_period := kut._active_injury_period(v_player);
  if v_period is null then raise exception 'your player is not in injury mode' using errcode = 'P0001'; end if;
  -- Serialise against admin_end_injury and a concurrent check-in.
  perform 1 from kut.injury_periods where id = v_period and ended_on is null for update;
  if not found then raise exception 'your player is not in injury mode' using errcode = 'P0001'; end if;

  if exists (select 1 from kut.injury_check_ins where player_id = v_player and week_start = p_week_start) then
    return jsonb_build_object('checked_in', false, 'already_checked_in', true, 'week_start', p_week_start);
  end if;
  if not kut._injury_checkable_week(v_player, v_period, p_week_start) then
    raise exception 'this week is not open for a check-in' using errcode = 'P0001';
  end if;

  insert into kut.injury_check_ins (player_id, week_start, period_id, user_id, amount, ledger_id)
  values (v_player, p_week_start, v_period, v_user, v_amount, v_ledger)
  on conflict (player_id, week_start) do nothing;
  if not found then
    return jsonb_build_object('checked_in', false, 'already_checked_in', true, 'week_start', p_week_start);
  end if;

  insert into kut.wallets (user_id, balance) values (v_user, 0) on conflict do nothing;
  insert into kut.wallet_ledger (id, user_id, amount, reason, reference_type, reference_id, idempotency_key)
  values (v_ledger, v_user, v_amount, 'injury_stipend', 'injury_period', v_period,
    'injury:' || v_player::text || ':' || p_week_start::text);
  update kut.wallets set balance = balance + v_amount, updated_at = now()
  where user_id = v_user returning balance into v_balance;

  -- Show the protection now rather than at the next survey finalization. The
  -- advisory lock serialises check-in rebuilds of one season with each other.
  select id into v_season from kut.seasons where is_active;
  perform pg_advisory_xact_lock(hashtext('kut.rebuild_season'), hashtext(v_season::text));
  perform kut._rebuild_season_core(v_season);

  return jsonb_build_object('checked_in', true, 'already_checked_in', false, 'week_start', p_week_start,
    'amount', v_amount, 'balance', v_balance);
end $$;
revoke all on function kut.injury_check_in(date) from public, anon;
grant execute on function kut.injury_check_in(date) to authenticated, service_role;

-- 7. Club-wide projection -----------------------------------------------------------
-- A definer view (members cannot read kut.injury_periods), so it is gated on
-- kut.is_active_member() exactly as ADR-079 gates the other ten. The note is
-- never projected. The active rule is inlined rather than calling
-- kut._active_injury_period, because a view's function calls are checked
-- against the caller, who has no execute on that helper.

create view kut.injured_players
with (security_invoker = false, security_barrier = true)
as
select * from (
  select
    period.player_id,
    period.started_on,
    (select count(*) from kut.injury_check_ins c where c.period_id = period.id)::integer as protected_weeks
  from kut.injury_periods period
  where period.ended_on is null
    and not exists (
      select 1 from kut.attendance a
      join kut.match_sessions s on s.id = a.session_id
      where a.player_id = period.player_id
        and s.status = 'published'
        and s.session_date > period.started_on
    )
) gated
where kut.is_active_member();

comment on view kut.injured_players is
  'ADR-082: Players currently in injury mode (open period, not played since), for the card badge. Never exposes the admin note. Gated on kut.is_active_member() (ADR-079): a denied caller reads zero rows.';
revoke all on kut.injured_players from public, anon;
grant select on kut.injured_players to authenticated, service_role;

-- 8. "Rehab check-in is open" notice ----------------------------------------------
-- Fires when a week's FIRST published session of the active season appears, for
-- a recent week only (a backfilled old session opens nothing). Attendance is
-- inserted before publish_session flips the status, so a Player who just
-- returned is already excluded by the derived active rule.

create function kut._notify_injury_check_in_open()
returns trigger language plpgsql security definer set search_path = kut, pg_catalog as $$
declare v_week date := date_trunc('week', new.session_date)::date;
begin
  if new.status = 'published' and old.status is distinct from 'published'
    and v_week >= date_trunc('week', (now() at time zone 'Europe/Amsterdam')::date)::date - 7
    and exists (select 1 from kut.seasons where id = new.season_id and is_active)
    and not exists (
      select 1 from kut.match_sessions s
      where s.id <> new.id and s.status = 'published' and date_trunc('week', s.session_date)::date = v_week
    )
  then
    insert into kut.user_notifications (user_id, event_type, title, body, reference_type, reference_id)
    select profile.id, 'injury_check_in', 'Rehab check-in is open',
      'This week counts as a football week. Check in from Home to receive 100 KUT Coins and keep your card rating protected.',
      'match_session', new.id
    from kut.injury_periods period
    join kut.profiles profile on profile.player_id = period.player_id and not profile.is_disabled
    where period.ended_on is null
      and kut._active_injury_period(period.player_id) = period.id
      and v_week >= date_trunc('week', period.started_on)::date
    on conflict (user_id, event_type, reference_type, reference_id)
      where reference_type is not null and reference_id is not null do nothing;
  end if;
  return new;
end $$;
revoke execute on function kut._notify_injury_check_in_open() from public, anon, authenticated;
create trigger match_sessions_injury_check_in_notice after update of status on kut.match_sessions
for each row execute function kut._notify_injury_check_in_open();
