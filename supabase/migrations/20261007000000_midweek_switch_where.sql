-- Midweek Madness: the launch switch works through the API (KB-024).
-- BUILD_SPEC §44.8; ADR-095.
--
-- kut.admin_set_midweek_enabled updated its single-row config with no WHERE
-- clause. Supabase preloads the safeupdate extension for the `authenticator`
-- role that PostgREST connects as, and safeupdate rejects an UPDATE or DELETE
-- without a WHERE (SQLSTATE 21000), even inside a security-definer function.
-- So on hosted the admin page's "Paused -> Running" switch failed every time,
-- while pgTAP and the integration suites, which connect as postgres, passed.
--
--   * The function is re-created with `where id` (the config row's key is
--     always true), identical otherwise: same checks, errors, grants and
--     return value.
--   * No other kut function has an UPDATE or DELETE without a WHERE; the
--     database test for this file pins that for every function in the schema.
--
-- Tier: additive (ADR-032). One `create or replace function`; no row is
-- written. Rides the last scheduled backup.
--
-- Rollback: re-create kut.admin_set_midweek_enabled from
-- 20261005000000_midweek_engine.sql section 6 (the switch is then unusable
-- through the API again).

create or replace function kut.admin_set_midweek_enabled(p_enabled boolean)
returns jsonb language plpgsql security definer set search_path = kut, pg_catalog as $$
begin
  if not kut.is_admin() then raise exception 'admin role required' using errcode = '42501'; end if;
  if p_enabled is null then raise exception 'say whether Midweek Madness runs' using errcode = '22023'; end if;
  -- The single config row, named: safeupdate refuses an UPDATE without a WHERE.
  update kut.midweek_config set enabled = p_enabled, updated_at = now(), updated_by = auth.uid()
  where id;
  return jsonb_build_object('enabled', p_enabled);
end $$;
revoke all on function kut.admin_set_midweek_enabled(boolean) from public, anon;
grant execute on function kut.admin_set_midweek_enabled(boolean) to authenticated, service_role;
