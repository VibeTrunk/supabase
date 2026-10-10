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
4. Live migrations go through `.github/workflows/apply-migrations.yml`
   (README): a kut backup under an hour old, a plan of KUT-only migrations,
   the owner's approval of the `production` environment, then the push. Its
   database password exists only as that environment's secret.
5. Never use `migration repair` to hide an unexpected version. Investigate the
   source repository and add its original migration to this catalogue instead.
6. Locally, credentials belong only in an ignored `.env.local`. Never print
   them or put them in a command transcript.

## Catalogue log

Every catalogued migration, with its tier, backup, pre- and post-push
`migration list --linked` counts, hosted smoke test and rollback, is in
[`CATALOGUE.md`](CATALOGUE.md). Add new entries there, never here, so this
file stays orientation.

**Latest applied migration:** KUT's `20261019000000_basic_pack_price_250.sql`
(catalogue PR #81), applied 2026-10-08; all 89 local/remote versions match,
with no pending migrations or drift. Verification and rollback: CATALOGUE.md.

## Repo status

- Branch protection on `main` enabled 2026-08-23 (squash-only merges, PRs
  required, direct pushes blocked including for admins). See the global
  `~/.claude/CLAUDE.md` "Branch workflow" section for the actual branch/PR
  conventions to follow.
