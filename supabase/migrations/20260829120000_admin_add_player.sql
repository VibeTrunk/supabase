-- Server-authoritative "add a player to the roster" so admins register a new
-- TFH member from the admin UI instead of a one-off migration. Mirrors the
-- roster + Live edition + rebuild steps that
-- 20260818000000_initial_tfh_roster_and_august_sessions.sql performed by hand.
-- See ADR-025.

create or replace function kut.admin_add_player(
  p_display_name text,
  p_archetype    text default 'all_rounder',
  p_full_name    text default null
)
returns jsonb
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
declare
  v_display_name text := nullif(btrim(p_display_name), '');
  v_full_name    text := nullif(btrim(coalesce(p_full_name, '')), '');
  v_base_slug    text;
  v_slug         text;
  v_suffix       integer := 1;
  v_player_id    uuid;
  v_season_id    uuid;
begin
  if not kut.is_admin() then
    raise exception 'admin access required' using errcode = '42501';
  end if;

  if v_display_name is null or char_length(v_display_name) > 80 then
    raise exception 'display name must be 1-80 characters' using errcode = '22023';
  end if;

  if p_archetype is null or p_archetype not in
     ('all_rounder','speedster','finisher','playmaker','defender','tank') then
    raise exception 'invalid archetype: %', p_archetype using errcode = '22023';
  end if;

  v_base_slug := btrim(regexp_replace(lower(v_display_name), '[^a-z0-9]+', '-', 'g'), '-');
  if v_base_slug = '' then
    raise exception 'display name has no usable slug characters' using errcode = '22023';
  end if;

  v_slug := v_base_slug;
  while exists (select 1 from kut.players where slug = v_slug) loop
    v_suffix := v_suffix + 1;
    v_slug := v_base_slug || '-' || v_suffix;
  end loop;

  insert into kut.players (slug, display_name, full_name, archetype)
  values (v_slug, v_display_name, v_full_name, p_archetype)
  returning id into v_player_id;

  insert into kut.card_editions (player_id, edition_type, title, is_live)
  values (v_player_id, 'live', v_display_name || ' Live', true)
  on conflict do nothing;

  -- baseline season-state row via the canonical rebuild so the player shows in
  -- Live Ratings immediately (30 OVR / common until they attend). Idempotent;
  -- skips cleanly with no active season.
  select id into v_season_id from kut.seasons where is_active limit 1;
  if v_season_id is not null then
    perform kut._rebuild_season_core(v_season_id);
  end if;

  return jsonb_build_object(
    'player_id', v_player_id,
    'slug', v_slug,
    'display_name', v_display_name,
    'archetype', p_archetype
  );
end;
$$;

revoke execute on function kut.admin_add_player(text, text, text) from public, anon;
grant  execute on function kut.admin_add_player(text, text, text) to authenticated;
