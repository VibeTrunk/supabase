-- Roster management for the /admin/roster UI. Two server-authoritative paths,
-- both gated by kut.is_admin() the same way admin_add_player is:
--
--   * admin_set_player_active — a soft, reversible deactivate/reactivate. A
--     deactivated player leaves public_live_ratings and the open_pack pool
--     (both filter players.is_active) but keeps their row, attendance history,
--     season-state, and any card copies people already own.
--
--   * admin_delete_player — a narrow HARD delete, allowed only for a player
--     who was never used: no attendance, no linked profile, no invitation, and
--     nobody owns a copy of their card. It also removes the auto-minted Live
--     edition and the baseline season-state row. Anything with history must be
--     deactivated instead.
--
-- See ADR-026.

create or replace function kut.admin_set_player_active(
  p_player_id uuid,
  p_is_active boolean
)
returns jsonb
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
declare
  v_slug         text;
  v_display_name text;
begin
  if not kut.is_admin() then
    raise exception 'admin access required' using errcode = '42501';
  end if;

  if p_is_active is null then
    raise exception 'is_active must be true or false' using errcode = '22023';
  end if;

  update kut.players
     set is_active = p_is_active
   where id = p_player_id
   returning slug, display_name into v_slug, v_display_name;

  if not found then
    raise exception 'player not found' using errcode = 'P0002';
  end if;

  return jsonb_build_object(
    'player_id', p_player_id,
    'slug', v_slug,
    'display_name', v_display_name,
    'is_active', p_is_active
  );
end;
$$;

create or replace function kut.admin_delete_player(p_player_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
declare
  v_slug         text;
  v_display_name text;
begin
  if not kut.is_admin() then
    raise exception 'admin access required' using errcode = '42501';
  end if;

  select slug, display_name into v_slug, v_display_name
  from kut.players where id = p_player_id;

  if not found then
    raise exception 'player not found' using errcode = 'P0002';
  end if;

  if exists (select 1 from kut.attendance where player_id = p_player_id)
     or exists (select 1 from kut.profiles where player_id = p_player_id)
     or exists (select 1 from kut.invitations where player_id = p_player_id)
     or exists (
       select 1
       from kut.user_cards uc
       join kut.card_editions ce on ce.id = uc.edition_id
       where ce.player_id = p_player_id
     )
  then
    raise exception
      'player % has attendance, an account, an invite, or owned cards and cannot be deleted; deactivate instead',
      v_slug
      using errcode = 'P0001';
  end if;

  delete from kut.player_season_state where player_id = p_player_id;
  delete from kut.card_editions       where player_id = p_player_id;
  delete from kut.players             where id = p_player_id;

  return jsonb_build_object(
    'deleted_player_id', p_player_id,
    'slug', v_slug,
    'display_name', v_display_name
  );
exception
  when foreign_key_violation then
    -- backstop for any linked record the explicit checks above did not cover.
    raise exception
      'player % still has linked records and cannot be deleted; deactivate instead',
      v_slug
      using errcode = 'P0001';
end;
$$;

revoke execute on function kut.admin_set_player_active(uuid, boolean) from public, anon;
grant  execute on function kut.admin_set_player_active(uuid, boolean) to authenticated;

revoke execute on function kut.admin_delete_player(uuid) from public, anon;
grant  execute on function kut.admin_delete_player(uuid) to authenticated;
