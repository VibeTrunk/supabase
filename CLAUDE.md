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
- KUT migrations through `20260817030000_private_live_ratings.sql` are
  catalogued for the first KUT hosted release.
