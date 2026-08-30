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
- `20260830000000` / `20260831000000` / `20260901000000` (**applied
  2026-08-30**): KUT's alpha-readiness batch, ADR-027..030.
  Member `player_directory` view + ownership-gated self-service RPCs (own card
  photo + archetype), a private `player-photos` storage bucket with
  folder-scoped `storage.objects` RLS, `profiles.username` login handle,
  `admin_set_profile_player` / `admin_set_account_disabled` /
  `admin_prepare_account_deletion`, a dated attendance-reward inbox message
  (amount 75 → 250, not retroactive), and a members-only
  `club_value_leaderboard`. First migration to touch the `storage` schema.
  Pushed as one batch from this repo after KUT PR #8 merged; the
  `player-photos` bucket (private, 5 MiB, webp/jpeg/png) and its four
  `storage.objects` policies were confirmed on the hosted project.
- `20260902000000_starter_reveal_and_rating_snapshots.sql` (**applied
  2026-08-30**): KUT's ADR-031. Adds
  `kut.player_rating_snapshots` + an `after`-trigger on
  `kut.player_season_state` (`kut.capture_rating_snapshot`) that upserts a
  per-week OVR snapshot keyed on `last_week_start`, the `kut.top_risers` view
  (two-most-recent-weeks positive delta), `kut.profiles.starter_opened_at`
  (backfilled `= starter_claimed_at`), `kut.mark_starter_opened()`, and
  widens `kut.my_pack_opening_results` with `players.photo_path` (`create or
  replace view`, append-only). Migration-time seed inserts the current week's
  snapshots. Rollback DDL is in the migration header. Pushed from this repo
  2026-08-30 (KUT PR #10 was already merged); `kut.player_rating_snapshots`,
  `kut.top_risers`, `kut.profiles.starter_opened_at`, `kut.mark_starter_opened`
  and `kut.my_pack_opening_results.photo_path` confirmed on the hosted project.
- `20260903000000_drop_is_tradeable.sql` (**applied 2026-08-31**): KUT's
  ADR-033. Retires the untradeable card concept — drops
  `kut.user_cards.is_tradeable`, rebuilds `kut.my_collection_cards` (`drop
  view` + `create view`, since a column can't be dropped via `create or
  replace view`), and recreates `grant_starter_pack`, `open_pack`,
  `discard_card`, `get_listing_bounds`, `create_listing`, `buy_listing`
  without the flag. Data-changing tier (ADR-032): fresh encrypted backup
  immediately before the push; lossless reverse DDL in the migration header
  (every surviving row was `true`). Pushed from this repo 2026-08-31 after
  KUT PR #17 merged; a hosted `kut` dump confirms zero `is_tradeable`
  references, the six recreated functions, and `user_cards` without the
  column.

## Repo status

- Branch protection on `main` enabled 2026-08-23 (squash-only merges, PRs
  required, direct pushes blocked including for admins). See the global
  `~/.claude/CLAUDE.md` "Branch workflow" section for the actual branch/PR
  conventions to follow.
