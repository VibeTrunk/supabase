create table kut.invitations (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references kut.players(id) on delete restrict,
  token_hash text not null unique check (token_hash ~ '^[a-f0-9]{64}$'),
  expires_at timestamptz not null default (now() + interval '14 days'),
  created_by uuid references kut.profiles(id) on delete set null,
  consumed_at timestamptz,
  consumed_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  check ((consumed_at is null) = (consumed_by is null)),
  check (expires_at > created_at)
);

create index invitations_player_idx on kut.invitations (player_id);
create index invitations_unconsumed_idx on kut.invitations (expires_at) where consumed_at is null;

grant select, insert, update, delete on kut.invitations to authenticated, service_role;

alter table kut.invitations enable row level security;

create policy "admins manage invitations" on kut.invitations
  for all to authenticated using (kut.is_admin()) with check (kut.is_admin());

create or replace function kut.claim_invitation(
  p_token_hash text,
  p_user_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
declare
  v_player_id uuid;
  v_display_name text;
begin
  if p_token_hash !~ '^[a-f0-9]{64}$' then
    raise exception 'invite is invalid or expired' using errcode = '22023';
  end if;

  select invitation.player_id, player.display_name
  into v_player_id, v_display_name
  from kut.invitations invitation
  join kut.players player on player.id = invitation.player_id
  where invitation.token_hash = p_token_hash
    and invitation.consumed_at is null
    and invitation.expires_at > now()
    and player.is_active
  for update of invitation;

  if v_player_id is null then
    raise exception 'invite is invalid or expired' using errcode = '22023';
  end if;

  insert into kut.profiles (id, display_name, role, player_id)
  values (p_user_id, v_display_name, 'user', v_player_id);

  update kut.invitations
  set consumed_at = now(), consumed_by = p_user_id
  where token_hash = p_token_hash;

  return v_player_id;
end;
$$;

revoke execute on function kut.claim_invitation(text, uuid) from public, anon, authenticated;
grant execute on function kut.claim_invitation(text, uuid) to service_role;
