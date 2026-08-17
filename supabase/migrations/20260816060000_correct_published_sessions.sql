create table kut.session_corrections (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references kut.match_sessions(id) on delete restrict,
  previous_session_date date not null,
  previous_session_type text not null check (previous_session_type in ('monday', 'friday', 'other')),
  previous_attendance jsonb not null check (jsonb_typeof(previous_attendance) = 'array'),
  corrected_session_date date not null,
  corrected_session_type text not null check (corrected_session_type in ('monday', 'friday', 'other')),
  corrected_attendance jsonb not null check (jsonb_typeof(corrected_attendance) = 'array'),
  reason text not null check (char_length(reason) between 3 and 500),
  corrected_by uuid references kut.profiles(id) on delete set null,
  corrected_at timestamptz not null default now()
);

create index session_corrections_session_idx on kut.session_corrections (session_id, corrected_at desc);

alter table kut.session_corrections enable row level security;

create policy "admins read session corrections" on kut.session_corrections
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

  select season_id, session_date, session_type
  into v_season_id, v_previous_session_date, v_previous_session_type
  from kut.match_sessions
  where id = p_session_id and status = 'published'
  for update;

  if v_season_id is null then
    raise exception 'published session not found' using errcode = 'P0002';
  end if;

  select count(*), count(distinct (item ->> 'player_id')::uuid)
  into v_attendee_count, v_known_player_count
  from jsonb_array_elements(p_attendance) as item;

  if v_attendee_count <> v_known_player_count then
    raise exception 'each player can attend only once' using errcode = '22023';
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object('player_id', player_id, 'goals', goals)
      order by player_id
    ),
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
    session_id,
    previous_session_date,
    previous_session_type,
    previous_attendance,
    corrected_session_date,
    corrected_session_type,
    corrected_attendance,
    reason,
    corrected_by
  ) values (
    p_session_id,
    v_previous_session_date,
    v_previous_session_type,
    v_previous_attendance,
    p_session_date,
    p_session_type,
    p_attendance,
    trim(p_reason),
    auth.uid()
  );

  delete from kut.attendance where session_id = p_session_id;

  insert into kut.attendance (session_id, player_id, goals)
  select
    p_session_id,
    (item ->> 'player_id')::uuid,
    (item ->> 'goals')::integer
  from jsonb_array_elements(p_attendance) as item;

  update kut.match_sessions
  set session_date = p_session_date,
      session_type = p_session_type
  where id = p_session_id;

  perform kut.rebuild_season(v_season_id);

  return p_session_id;
end;
$$;

revoke execute on function kut.correct_published_attendance_session(uuid, date, text, jsonb, text) from public, anon;
grant execute on function kut.correct_published_attendance_session(uuid, date, text, jsonb, text) to authenticated, service_role;
