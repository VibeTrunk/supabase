# VibeTrunk shared Supabase migrations

## Purpose

VibeTrunk tools share one hosted Supabase project. Supabase stores migration
history globally, not per Postgres schema. This repository is the canonical
catalogue and deployment point for that global history.

The current project ref is intentionally documented only in private operator
configuration, never committed here. Each tool continues to own its schema,
application code, and local database tests.

## Rules

1. Run live migrations only from this repository.
2. Keep each migration in `supabase/migrations/` immutable once applied.
3. A tool schema change requires the same SQL file in this catalogue and in
   the owning tool repository. `scripts/verify-catalog.ps1` checks the current
   KUT and Cogitster copies.
4. Before a live migration: create a verified encrypted backup, run the
   catalogue check, list remote migrations, and run `supabase db push --dry-run`.
5. Never use `migration repair` to hide an unexpected version. Investigate the
   source repository and add its original migration to this catalogue instead.
6. Credentials belong only in an ignored `.env.local`. Never print them or put
   them in a command transcript.

## Initial catalogue

- `202608160001_cogitster_solo.sql` was already applied to the shared project.
- Cogitster's `202608160002_lock_down_trigger_execute.sql` is intentionally
  not catalogued yet because it has not been applied and is unrelated to the
  KUT release.
- KUT migrations through
  `20260829130000_admin_manage_roster.sql` are catalogued and applied to the
  hosted project. `20260829000000` (applied 2026-08-29) completed August
  2026: sessions 21.08 / 28.08 and four new 2+-appearance players (Steffen,
  Serhat, Stephen, Maarten). `20260829120000_admin_add_player.sql` and
  `20260829130000_admin_manage_roster.sql` (applied 2026-08-29) are
  function-only: KUT's server-authoritative roster RPCs (`admin_add_player`,
  ADR-025; `admin_set_player_active` / `admin_delete_player`, ADR-026) so the
  roster is managed from `/admin/roster` rather than a migration each time.
- `20260830000000` / `20260831000000` / `20260901000000` (catalogued
  2026-08-29, **not yet applied**): KUT's alpha-readiness batch, ADR-027..030.
  Member `player_directory` view + ownership-gated self-service RPCs (own card
  photo + archetype), a private `player-photos` storage bucket with
  folder-scoped `storage.objects` RLS, `profiles.username` login handle,
  `admin_set_profile_player` / `admin_set_account_disabled` /
  `admin_prepare_account_deletion`, a dated attendance-reward inbox message
  (amount 75 → 250, not retroactive), and a members-only
  `club_value_leaderboard`. First migration to touch the `storage` schema.
  Deploys as one batch after KUT PR #8 is approved.

## Repo status

- Branch protection on `main` enabled 2026-08-23 (squash-only merges, PRs
  required, direct pushes blocked including for admins). See the global
  `~/.claude/CLAUDE.md` "Branch workflow" section for the actual branch/PR
  conventions to follow.
