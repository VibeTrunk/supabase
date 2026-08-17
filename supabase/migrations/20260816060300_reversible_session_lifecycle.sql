alter table kut.match_sessions
  drop constraint match_sessions_status_timestamps_check,
  add constraint match_sessions_status_timestamps_check check (
    (status = 'published') = (published_at is not null)
    and (status <> 'cancelled' or (
      cancelled_at is not null
      and char_length(cancellation_reason) between 3 and 500
    ))
  );

alter table kut.match_sessions
  drop constraint match_sessions_season_id_session_date_session_type_key;

create unique index match_sessions_active_slot_idx
  on kut.match_sessions (season_id, session_date, session_type)
  where status in ('draft', 'published');

create table kut.session_status_events (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references kut.match_sessions(id) on delete restrict,
  event_type text not null check (event_type in ('cancelled', 'reactivated')),
  reason text not null check (char_length(reason) between 3 and 500),
  performed_by uuid references kut.profiles(id) on delete set null,
  occurred_at timestamptz not null default now(),
  unique (session_id, event_type, occurred_at)
);

create index session_status_events_session_idx on kut.session_status_events (session_id, occurred_at desc);

insert into kut.session_status_events (session_id, event_type, reason, performed_by, occurred_at)
select id, 'cancelled', cancellation_reason, cancelled_by, cancelled_at
from kut.match_sessions
where status = 'cancelled' and cancelled_at is not null
on conflict do nothing;

grant select on kut.session_status_events to authenticated, service_role;
alter table kut.session_status_events enable row level security;
create policy "admins read session status events" on kut.session_status_events
  for select to authenticated using (kut.is_admin());

create or replace function kut.correct_published_attendance_session(
  p_session_id uuid,
  p_session_date date,
  p_session_type text,
  p_attendance jsonb,
  p_reason text
)
returns uuid
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
declare
  v_season_id uuid;
  v_status text;
  v_previous_session_date date;
  v_previous_session_type text;
  v_previous_attendance jsonb;
  v_attendee_count integer;
  v_known_player_count integer;
begin
  if not kut.is_admin() then
    raise exception 'admin access required' using errcode = '42501';
  end if;

  if p_session_type not in ('monday', 'friday', 'other') then
    raise exception 'invalid session type' using errcode = '22023';
  end if;

  if jsonb_typeof(p_attendance) <> 'array' or jsonb_array_length(p_attendance) = 0 then
    raise exception 'attendance must contain at least one player' using errcode = '22023';
  end if;

  if char_length(trim(coalesce(p_reason, ''))) not between 3 and 500 then
    raise exception 'a correction reason is required' using errcode = '22023';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_attendance) as item
    where jsonb_typeof(item -> 'player_id') <> 'string'
      or (item ->> 'player_id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
      or jsonb_typeof(item -> 'goals') <> 'number'
      or not ((item ->> 'goals') ~ '^[0-9]+$')
  ) then
    raise exception 'attendance contains an invalid player or goal total' using errcode = '22023';
  end if;

  select season_id, status, session_date, session_type
  into v_season_id, v_status, v_previous_session_date, v_previous_session_type
  from kut.match_sessions
  where id = p_session_id and status in ('published', 'cancelled')
  for update;

  if v_season_id is null then
    raise exception 'published or cancelled session not found' using errcode = 'P0002';
  end if;

  select count(*), count(distinct (item ->> 'player_id')::uuid)
  into v_attendee_count, v_known_player_count
  from jsonb_array_elements(p_attendance) as item;

  if v_attendee_count <> v_known_player_count then
    raise exception 'each player can attend only once' using errcode = '22023';
  end if;

  select coalesce(
    jsonb_agg(jsonb_build_object('player_id', player_id, 'goals', goals) order by player_id),
    '[]'::jsonb
  ) into v_previous_attendance
  from kut.attendance
  where session_id = p_session_id;

  select count(*) into v_known_player_count
  from kut.players p
  join jsonb_array_elements(p_attendance) as item
    on p.id = (item ->> 'player_id')::uuid
  where p.is_active
    or exists (
      select 1 from kut.attendance a
      where a.session_id = p_session_id and a.player_id = p.id
    );

  if v_known_player_count <> v_attendee_count then
    raise exception 'attendance contains an unknown or inactive player' using errcode = '22023';
  end if;

  insert into kut.session_corrections (
    session_id, previous_session_date, previous_session_type, previous_attendance,
    corrected_session_date, corrected_session_type, corrected_attendance, reason, corrected_by
  ) values (
    p_session_id, v_previous_session_date, v_previous_session_type, v_previous_attendance,
    p_session_date, p_session_type, p_attendance, trim(p_reason), auth.uid()
  );

  delete from kut.attendance where session_id = p_session_id;
  insert into kut.attendance (session_id, player_id, goals)
  select p_session_id, (item ->> 'player_id')::uuid, (item ->> 'goals')::integer
  from jsonb_array_elements(p_attendance) as item;

  update kut.match_sessions
  set session_date = p_session_date,
      session_type = p_session_type
  where id = p_session_id;

  if v_status = 'published' then
    perform kut.rebuild_season(v_season_id);
  end if;

  return p_session_id;
end;
$$;

create or replace function kut.cancel_published_session(
  p_session_id uuid,
  p_reason text
)
returns uuid
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
declare
  v_season_id uuid;
begin
  if not kut.is_admin() then
    raise exception 'admin access required' using errcode = '42501';
  end if;

  if char_length(trim(coalesce(p_reason, ''))) not between 3 and 500 then
    raise exception 'a cancellation reason is required' using errcode = '22023';
  end if;

  update kut.match_sessions
  set status = 'cancelled', published_at = null, cancelled_at = now(),
      cancelled_by = auth.uid(), cancellation_reason = trim(p_reason)
  where id = p_session_id and status = 'published'
  returning season_id into v_season_id;

  if v_season_id is null then
    raise exception 'published session not found' using errcode = 'P0002';
  end if;

  insert into kut.session_status_events (session_id, event_type, reason, performed_by)
  values (p_session_id, 'cancelled', trim(p_reason), auth.uid());

  perform kut.rebuild_season(v_season_id);
  return p_session_id;
end;
$$;

create or replace function kut.reactivate_cancelled_session(
  p_session_id uuid,
  p_reason text
)
returns uuid
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
declare
  v_season_id uuid;
begin
  if not kut.is_admin() then
    raise exception 'admin access required' using errcode = '42501';
  end if;

  if char_length(trim(coalesce(p_reason, ''))) not between 3 and 500 then
    raise exception 'a reactivation reason is required' using errcode = '22023';
  end if;

  update kut.match_sessions
  set status = 'published', published_at = now()
  where id = p_session_id and status = 'cancelled'
  returning season_id into v_season_id;

  if v_season_id is null then
    raise exception 'cancelled session not found' using errcode = 'P0002';
  end if;

  insert into kut.session_status_events (session_id, event_type, reason, performed_by)
  values (p_session_id, 'reactivated', trim(p_reason), auth.uid());

  perform kut.rebuild_season(v_season_id);
  return p_session_id;
end;
$$;

revoke execute on function kut.reactivate_cancelled_session(uuid, text) from public, anon;
grant execute on function kut.reactivate_cancelled_session(uuid, text) to authenticated, service_role;
