-- ADR-081 -- kut.season_rating_rules gets RLS and one active-member read policy.
--
-- Tier: additive, access-only. No table is created or altered beyond its RLS
-- flag, no column changes, no grant changes, no DML. Rides the scheduled backup.
--
-- The finding (Supabase Security Advisor, 2026-09-16). kut.season_rating_rules
-- -- one row per season, its rating-v2 cutover week -- is the only table in the
-- exposed `kut` schema with RLS disabled, against the build spec's "RLS on
-- every table". It is NOT a current hole: 20260920070000 already revokes
-- public/anon and grants only SELECT to authenticated and service_role, and
-- nobody holds INSERT, UPDATE or DELETE. What it did leave open is the KB-017
-- shape in miniature: a JWT minted for another VibeTrunk tool in this shared
-- project, or a disabled KUT account with a still-valid session, could read the
-- cutover dates. This closes that and the deviation; it is defense in depth.
--
-- The policy reuses kut.is_active_member() (ADR-079) rather than a new helper.
-- It FILTERS, never raises: a denied caller reads zero rows, the same contract
-- as the ten gated projections. No role filter -- the one app reader,
-- src/app/(app)/admin/attendance/page.tsx, is an authenticated admin, and admins
-- pass the predicate. The service role is not named in the policy: it has
-- BYPASSRLS, so policies never apply to it.
--
-- No write policies and no grant change. With RLS on and no INSERT/UPDATE/
-- DELETE policy, writes would be denied even if a grant ever appeared; today the
-- missing grant already refuses them with 42501 before RLS is consulted.
--
-- Every other reader and writer is `security definer`, owned by the table
-- owner, with search_path = kut, pg_catalog:
--   kut._rebuild_season_core            (reads the cutover; via kut.rebuild_season
--                                        and the finalizer)
--   kut._version_and_open_session_survey (match_sessions_rating_version trigger;
--                                        stamps rating_rules_version on publish)
--   kut.initialize_season_rating_rules  (seasons_initialize_rating_rules trigger;
--                                        seeds the row for a new season)
-- They keep working because a table's owner bypasses its RLS.
--
-- Deliberately NOT `force row level security`. Measured on the local stack
-- first: under FORCE with no policy at all the three definer paths above still
-- worked, because the owning role `postgres` also carries BYPASSRLS there. So
-- FORCE would not break them today. It is still left off: it would buy nothing,
-- since the only code running as the owner is those three reviewed definer
-- functions, and it would rest them on a role attribute the platform grants and
-- this repository cannot pin, instead of the bypass Postgres gives every owner. The database test pins relforcerowsecurity = false and
-- that each definer function is owned by the table's owner.
--
-- Rollback:
--   drop policy "active members read rating rules" on kut.season_rating_rules;
--   alter table kut.season_rating_rules disable row level security;
--   Grants are unchanged by this migration, so none need re-granting.
--
-- Operator note: as with the ADR-079 views, kut.is_active_member() is false for
-- a bare psql session with no JWT and no SET ROLE -- but a bare `postgres`
-- session bypasses RLS here anyway, so an ad-hoc read of this table is
-- unaffected.

alter table kut.season_rating_rules enable row level security;

create policy "active members read rating rules"
  on kut.season_rating_rules
  for select
  to authenticated
  using (kut.is_active_member());
