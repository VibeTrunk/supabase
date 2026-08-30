# VibeTrunk Supabase

Central migration catalogue for the single shared VibeTrunk Supabase project.

## Operator workflow

1. Make the schema change in the owning app repository and verify it locally.
2. Copy the immutable migration, unchanged, into this repository.
3. Run `powershell -ExecutionPolicy Bypass -File scripts/verify-catalog.ps1`.
4. Commit and review both repositories together.
5. From this repository only, create a verified encrypted backup, run
   `npx supabase migration list --linked`, then `npx supabase db push --dry-run`.
6. Apply with `npx supabase db push` only after explicit operator approval.

Individual tool repositories must never attempt to deploy their migrations to
the shared project. This prevents Supabase's global migration ledger from
mistaking another tool's already-applied migration for missing local work.

## Current hosted ledger

The shared ledger contains Cogitster's deployed
`202608160001_cogitster_solo.sql` baseline and KUT's applied migrations through
`20260904000000_canonical_coin_name.sql`. Cogitster's
pending `202608160002_lock_down_trigger_execute.sql` is intentionally absent
until its own release is approved.

- `20260818000000_initial_tfh_roster_and_august_sessions.sql` (applied
  2026-08-18): the first real TFH roster/attendance data, and the reweighted
  activity rating formula from KUT's ADR-024.
- `20260829000000_august_2026_full_month_roster_and_sessions.sql` (applied
  2026-08-29): the two remaining August 2026 sessions (21.08, 28.08) and four
  players who reached 2+ appearances (Steffen, Serhat, Stephen, Maarten).
- `20260829120000_admin_add_player.sql` and
  `20260829130000_admin_manage_roster.sql` (applied 2026-08-29): function-only.
  KUT's server-authoritative roster RPCs — `admin_add_player` (ADR-025) plus
  `admin_set_player_active` / `admin_delete_player` (ADR-026) — so admins add
  and remove TFH members from `/admin/roster` instead of a migration per
  roster change.
- `20260830000000_member_self_service_and_player_directory.sql`,
  `20260831000000_admin_links_username_and_attendance_messages.sql`,
  `20260901000000_admin_manage_accounts_and_leaderboard.sql` (**applied
  2026-08-30**): KUT's alpha-readiness batch (ADR-027..030).
  Adds the member-facing `player_directory` view and two ownership-gated
  self-service RPCs (own card photo + archetype), a **private `player-photos`
  storage bucket** with folder-scoped `storage.objects` RLS, `profiles.username`
  as a login handle, `admin_set_profile_player` / `admin_set_account_disabled`
  / `admin_prepare_account_deletion`, a dated attendance-reward inbox message
  with the amount raised 75 → 250 (not retroactive), and makes
  `club_value_leaderboard` members-only. Touches the `storage` schema and
  widens `public_live_ratings` / `my_collection_cards` / `club_value_leaderboard`
  (`create or replace view`, append-only). Rollback DDL is in each migration
  header.
- `20260902000000_starter_reveal_and_rating_snapshots.sql` (**applied
  2026-08-30**): KUT's ADR-031. `kut.player_rating_snapshots`
  + an `after`-trigger on `kut.player_season_state` that upserts a per-week OVR
  snapshot, the `kut.top_risers` view, `kut.profiles.starter_opened_at`
  (backfilled `= starter_claimed_at`), `kut.mark_starter_opened()`, and widens
  `kut.my_pack_opening_results` with `players.photo_path` (`create or replace
  view`, append-only). A migration-time seed inserts the current week's
  snapshots. Rollback DDL is in the migration header.
- `20260903000000_drop_is_tradeable.sql` (**applied 2026-08-31**): KUT's
  ADR-033 — retires the untradeable card concept. Drops
  `kut.user_cards.is_tradeable`, rebuilds the `kut.my_collection_cards` view
  (`drop view` + `create view` — a column can't be removed via `create or
  replace view`), and recreates `grant_starter_pack`, `open_pack`,
  `discard_card`, `get_listing_bounds`, `create_listing`, `buy_listing`
  without the flag. Data-changing tier (ADR-032): a fresh encrypted
  `kut`-schema backup was taken immediately before the push; reverse DDL is
  in the migration header and is lossless (every surviving row was
  `is_tradeable = true`). Pushed from this repo 2026-08-31 after KUT PR #17
  merged; hosted dump confirms zero `is_tradeable` references, the six
  recreated functions, and `user_cards` with no such column.
- `20260904000000_canonical_coin_name.sql` (**applied 2026-08-31**): KUT's
  ADR-034 (tester feedback #7). "KUT Coins" is now the one currency name.
  `create or replace` of `kut.open_pack` + `kut.buy_listing` (latest
  `20260903000000` bodies) with `TF Coins` → `KUT Coins` in the two
  insufficient-funds `raise` strings and the two `market_purchase` /
  `market_sale` notification `format()` bodies, then a one-shot
  `update kut.user_notifications set body = replace(body, 'TF Coins', 'KUT
  Coins') where event_type in ('market_purchase','market_sale') and body like
  '%TF Coins%'` for rows already on hosted. Data-changing tier (ADR-032) only
  for that backfill: fresh encrypted backup immediately before the push;
  reverse `replace()` in the migration header, scoped to the same
  `event_type`s so it is lossless (`attendance_reward` bodies already said
  "KUT Coins"). No economy value, ledger `reason`, column, price, or formula
  change. Pushed from this repo 2026-08-31 after KUT PR #19 merged; a hosted
  `kut` dump shows zero `TF Coins` references and "KUT Coins" in both
  `open_pack` / `buy_listing` raises and both `buy_listing` notification
  bodies.
