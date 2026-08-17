alter table kut.match_sessions
  add column cancelled_at timestamptz,
  add column cancelled_by uuid references kut.profiles(id) on delete set null,
  add column cancellation_reason text;

alter table kut.match_sessions
  drop constraint match_sessions_check,
  add constraint match_sessions_status_timestamps_check check (
    (status = 'published') = (published_at is not null)
    and (status = 'cancelled') = (cancelled_at is not null)
    and (status <> 'cancelled' or char_length(cancellation_reason) between 3 and 500)
  );

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
  set status = 'cancelled',
      published_at = null,
      cancelled_at = now(),
      cancelled_by = auth.uid(),
      cancellation_reason = trim(p_reason)
  where id = p_session_id and status = 'published'
  returning season_id into v_season_id;

  if v_season_id is null then
    raise exception 'published session not found' using errcode = 'P0002';
  end if;

  perform kut.rebuild_season(v_season_id);

  return p_session_id;
end;
$$;

revoke execute on function kut.cancel_published_session(uuid, text) from public, anon;
grant execute on function kut.cancel_published_session(uuid, text) to authenticated, service_role;
