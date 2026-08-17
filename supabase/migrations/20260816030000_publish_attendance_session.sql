create or replace function kut.publish_attendance_session(
  p_season_id uuid,
  p_session_date date,
  p_session_type text,
  p_attendance jsonb
)
returns uuid
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
declare
  v_session_id uuid;
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

  if exists (
    select 1
    from jsonb_array_elements(p_attendance) as item
    where jsonb_typeof(item -> 'player_id') <> 'string'
      or jsonb_typeof(item -> 'goals') <> 'number'
      or not ((item ->> 'goals') ~ '^[0-9]+$')
  ) then
    raise exception 'attendance contains an invalid player or goal total' using errcode = '22023';
  end if;

  select count(*), count(distinct (item ->> 'player_id')::uuid)
  into v_attendee_count, v_known_player_count
  from jsonb_array_elements(p_attendance) as item;

  if v_attendee_count <> v_known_player_count then
    raise exception 'each player can attend only once' using errcode = '22023';
  end if;

  select count(*) into v_known_player_count
  from kut.players p
  join jsonb_array_elements(p_attendance) as item
    on p.id = (item ->> 'player_id')::uuid
  where p.is_active;

  if v_known_player_count <> v_attendee_count then
    raise exception 'attendance contains an unknown or inactive player' using errcode = '22023';
  end if;

  insert into kut.match_sessions (
    season_id,
    session_date,
    session_type,
    status,
    created_by
  ) values (
    p_season_id,
    p_session_date,
    p_session_type,
    'draft',
    auth.uid()
  ) returning id into v_session_id;

  insert into kut.attendance (session_id, player_id, goals)
  select
    v_session_id,
    (item ->> 'player_id')::uuid,
    (item ->> 'goals')::integer
  from jsonb_array_elements(p_attendance) as item;

  perform kut.publish_session(v_session_id);

  return v_session_id;
end;
$$;

revoke execute on function kut.publish_attendance_session(uuid, date, text, jsonb) from public, anon;
grant execute on function kut.publish_attendance_session(uuid, date, text, jsonb) to authenticated, service_role;
