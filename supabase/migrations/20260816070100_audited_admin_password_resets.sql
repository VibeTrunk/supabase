create table kut.password_reset_events (
  id uuid primary key default gen_random_uuid(),
  target_user_id uuid not null references kut.profiles(id) on delete restrict,
  reset_by uuid not null references kut.profiles(id) on delete restrict,
  reason text not null check (char_length(reason) between 3 and 500),
  status text not null default 'pending' check (status in ('pending', 'completed', 'failed')),
  created_at timestamptz not null default now(),
  completed_at timestamptz
);

create index password_reset_events_target_idx on kut.password_reset_events (target_user_id, created_at desc);

grant select on kut.password_reset_events to authenticated, service_role;
alter table kut.password_reset_events enable row level security;
create policy "admins read password reset audit" on kut.password_reset_events
  for select to authenticated using (kut.is_admin());

create or replace function kut.create_password_reset_event(
  p_target_user_id uuid,
  p_reason text
)
returns uuid
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
declare
  v_actor_role text;
  v_target_role text;
  v_event_id uuid;
begin
  if not kut.is_admin() then
    raise exception 'admin access required' using errcode = '42501';
  end if;

  if p_target_user_id = auth.uid() then
    raise exception 'admins cannot reset their own password here' using errcode = '22023';
  end if;

  if char_length(trim(coalesce(p_reason, ''))) not between 3 and 500 then
    raise exception 'a reset reason is required' using errcode = '22023';
  end if;

  select role into v_actor_role from kut.profiles where id = auth.uid();
  select role into v_target_role from kut.profiles where id = p_target_user_id and not is_disabled;

  if v_target_role is null then
    raise exception 'active target profile not found' using errcode = 'P0002';
  end if;

  if v_target_role in ('admin', 'superadmin') and v_actor_role <> 'superadmin' then
    raise exception 'only a superadmin can reset an administrator password' using errcode = '42501';
  end if;

  insert into kut.password_reset_events (target_user_id, reset_by, reason)
  values (p_target_user_id, auth.uid(), trim(p_reason))
  returning id into v_event_id;

  return v_event_id;
end;
$$;

create or replace function kut.complete_password_reset_event(
  p_event_id uuid,
  p_succeeded boolean
)
returns void
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
begin
  if not kut.is_admin() then
    raise exception 'admin access required' using errcode = '42501';
  end if;

  update kut.password_reset_events
  set status = case when p_succeeded then 'completed' else 'failed' end,
      completed_at = now()
  where id = p_event_id and reset_by = auth.uid() and status = 'pending';

  if not found then
    raise exception 'pending reset event not found' using errcode = 'P0002';
  end if;
end;
$$;

revoke execute on function kut.create_password_reset_event(uuid, text) from public, anon;
revoke execute on function kut.complete_password_reset_event(uuid, boolean) from public, anon;
grant execute on function kut.create_password_reset_event(uuid, text) to authenticated, service_role;
grant execute on function kut.complete_password_reset_event(uuid, boolean) to authenticated, service_role;
