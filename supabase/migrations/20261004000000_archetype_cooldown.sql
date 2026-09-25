-- Midweek Madness, migration B (20261004000000): the 14-day archetype cooldown.
-- BUILD_SPEC §44.2, §145 ARCHETYPE_CHANGE_COOLDOWN_DAYS; ADR-089, ADR-094.
--
-- A Midweek squad's lines are shaped by each card's archetype, frozen at the
-- lock (§44.2). Without a cooldown a member could retune their own card for the
-- week, say by becoming the club's only Goalkeeper on Wednesday afternoon. So a
-- member may change their own Player's archetype at most once every 14 days:
--
--   * kut.players gains archetype_changed_at, stamped by the self-service RPC
--     when the archetype actually changes. Null means "never changed through
--     self-service", so the first change is always allowed; nothing is
--     backfilled.
--   * kut.set_own_player_archetype refuses a change within 14 days of the last
--     one with SQLSTATE 22023. The DETAIL carries the exact next allowed moment
--     as an ISO-8601 UTC timestamp (microseconds) for the settings page.
--   * Saving the archetype the Player already has is not a change: it is
--     neither refused nor stamped (ADR-094).
--   * The admin path (kut.admin_add_player, admin SQL) is not limited and does
--     not stamp the column.
--
-- Tier: additive (ADR-032). One nullable column with no backfill and one
-- `create or replace function`; no existing row is rewritten. Rides the last
-- scheduled backup; no fresh pre-push backup required.
--
-- Rollback DDL:
--   -- re-create kut.set_own_player_archetype from 20260906000000 (section 3),
--   -- then:
--   alter table kut.players drop column archetype_changed_at;

-- 1. The stamp ------------------------------------------------------------------
alter table kut.players add column archetype_changed_at timestamptz;

comment on column kut.players.archetype_changed_at is
  'When the member last changed this Player''s archetype through '
  'kut.set_own_player_archetype. Null: never. Drives the 14-day cooldown '
  '(ADR-094); admin changes do not stamp it.';

-- 2. set_own_player_archetype: the cooldown guard -------------------------------
-- Identical to 20260906000000_goalkeeper_archetype.sql section 3 except:
--   * the Player row is read `for update`, so two concurrent saves cannot both
--     pass the guard;
--   * a change within 14 days of archetype_changed_at is refused (22023);
--   * a change stamps archetype_changed_at = now().
create or replace function kut.set_own_player_archetype(p_archetype text)
returns jsonb
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
declare
  v_player_id uuid;
  v_season_id uuid;
  v_current_archetype text;
  v_changed_at timestamptz;
  v_next_allowed timestamptz;
  v_is_change boolean;
begin
  select player_id into v_player_id
  from kut.profiles
  where id = auth.uid() and is_disabled = false;

  if v_player_id is null then
    raise exception 'no linked player for this account' using errcode = 'P0001';
  end if;

  if p_archetype is null or p_archetype not in
     ('all_rounder','speedster','finisher','playmaker','defender','tank','goalkeeper') then
    raise exception 'invalid archetype: %', p_archetype using errcode = '22023';
  end if;

  select archetype, archetype_changed_at
  into v_current_archetype, v_changed_at
  from kut.players
  where id = v_player_id
  for update;

  -- 14 days as 336 hours: an elapsed duration, independent of the session time
  -- zone, so it matches the settings page's arithmetic exactly.
  v_is_change := v_current_archetype is distinct from p_archetype;
  v_next_allowed := v_changed_at + interval '336 hours';

  if v_is_change and v_next_allowed is not null and now() < v_next_allowed then
    raise exception 'archetype change cooldown: next change allowed from %',
      to_char(v_next_allowed at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
      using errcode = '22023',
            detail = to_char(v_next_allowed at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"');
  end if;

  update kut.players
  set archetype = p_archetype,
      archetype_changed_at = case when v_is_change then now() else archetype_changed_at end
  where id = v_player_id;

  select id into v_season_id from kut.seasons where is_active limit 1;
  if v_season_id is not null then
    perform kut._rebuild_season_core(v_season_id);
  end if;

  return jsonb_build_object('player_id', v_player_id, 'archetype', p_archetype);
end;
$$;

revoke execute on function kut.set_own_player_archetype(text) from public, anon;
grant  execute on function kut.set_own_player_archetype(text) to authenticated;
