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
- `20260904000000_canonical_coin_name.sql` (**applied 2026-08-31**): KUT's
  ADR-034 (tester feedback #7). "KUT Coins" becomes the one currency name.
  `create or replace` of `open_pack` + `buy_listing` (latest `20260903000000`
  bodies) with `TF Coins` → `KUT Coins` in the two insufficient-funds `raise`
  strings and the two `market_purchase` / `market_sale` notification
  `format()` bodies, then a one-shot backfill of existing
  `kut.user_notifications` rows scoped to those event types. Data-changing
  tier (ADR-032) only for the backfill `UPDATE`: fresh encrypted backup
  immediately before the push; reverse `replace()` in the migration header,
  scoped so it is lossless (`attendance_reward` bodies already said "KUT
  Coins"). No economy value, ledger `reason`, column, price, or formula
  change. Pushed from this repo 2026-08-31 after KUT PR #19 merged; a hosted
  `kut` dump shows zero `TF Coins` references.
- `20260905000000_admin_economy_tools.sql` (**applied 2026-08-31**): KUT's
  ADR-035 (tester feedback #8 + #6). `kut.admin_adjust_wallet(uuid, bigint,
  text)` — audited coin faucet, both directions, `abs` cap 100000, never below
  zero, typed reason; `wallet_ledger.reason 'admin_grant'` + a
  `kut.admin_account_events` row + an `admin_notice` inbox message.
  `kut.admin_reset_account(uuid, uuid)` — soft reset: cancels active listings,
  soft-burns owned cards, deletes pack history + notifications, zeroes the
  wallet via a `-(balance)` + `+250` ledger pair (`reason 'admin_reset'`,
  net 250), re-grants the 3-card starter inline, nulls `starter_opened_at` to
  replay `/welcome`; keeps `market_sales`, market ledger rows and
  `attendance_rewards` guard rows; idempotent on `p_idempotency_key`.
  `kut.admin_account_events` audit table, admin-read RLS. `wallet_ledger.reason`
  check widened with `admin_grant` / `admin_reset`. Additive tier (ADR-032):
  all `create table` / `create or replace function` / one widened check; no
  data migration (the reset mutates rows at run time), so it rode the last
  scheduled backup. Reverse DDL in the migration header. Pushed from this repo
  2026-08-31 after KUT PR #21 + catalogue PR #15 merged; a hosted `kut` dump
  confirms `kut.admin_account_events` (+ partial unique index + RLS policy),
  both RPCs, and `wallet_ledger_reason_check` listing the two new reasons.
- `20260906000000_goalkeeper_archetype.sql` /
  `20260907000000_bibs_bonus.sql` / `20260908000000_activity_feed.sql`
  (**applied 2026-08-31**): KUT's Batch E (tester feedback #4 / #5 / #10 —
  ADR-036 / 037 / 038), the last tester-feedback batch. All three **additive
  tier (ADR-032)** — one `db push` on the last scheduled backup, no fresh
  pre-push backup; reverse DDL in each header.
  **E1** a seventh `goalkeeper` archetype reusing the six shared attributes
  (`pac -6, sho -12, pas 0, dri -8, def +14, phy +12`, sums to 0): widens the
  `kut.players` archetype `check` and `create or replace`s `admin_add_player`
  / `set_own_player_archetype` / `_rebuild_season_core` (a `when 'goalkeeper'`
  arm on each of the six attribute `CASE`s). No player pre-assigned, so no
  data change.
  **E2** a `+100` KUT Coins bonus for the bibs washer, coins only: nullable
  `kut.match_sessions.bibs_washed_by`, the `kut.bibs_rewards` guard table,
  `kut.grant_bibs_reward(uuid)` (called from
  `process_published_session_rewards`), `wallet_ledger.reason` +
  `user_notifications.event_type` widened with `bibs_bonus`, and a trailing
  `p_bibs_washed_by uuid default null` on `publish_`/`correct_` attendance
  RPCs (old signatures dropped + recreated, since a `create or replace` can't
  widen the arg list). Forward-only on corrections.
  **E3** one read-only `kut.activity_feed` view (`security_invoker = false`,
  `security_barrier = true`, `grant select to authenticated`) unioning
  completed sales, active listings, pack openings and published sessions; the
  sale rows expose the buyer name club-wide.
  Pushed from this repo 2026-08-31 after KUT PRs #23 / #24 / #25 + catalogue
  PR #17 merged; a hosted `kut` dump confirms all of the above, both attendance
  RPCs present only as the new 5-/6-arg signatures, and no drift on the 36
  prior migrations.
- `20260909000000_market_listing_card_art.sql` /
  `20260910000000_club_value_v2.sql` / `20260911000000_trade_offers.sql`
  (**applied 2026-08-31**): KUT's tester follow-up trio (ADR-040 / 041 / 042),
  catalogued and pushed via PR #19. `20260909` additive (`kut.active_market_listings`
  gains `photo_path` + `seller_id`); `20260910` data-changing (Club Value v2 —
  `my_club_value` dropped + recreated, `club_value_leaderboard` replaced,
  economy formula change) with a fresh pre-push backup; `20260911`
  data-changing (coin + card escrow trade offers — new `trade_offers` /
  `trade_offer_cards` tables, `user_cards.held_by_offer_id`, guards threaded
  through the market/discard/reset RPCs, `wallet_ledger.reason` +
  `user_notifications.event_type` widened, `activity_feed` gains a `trade`
  row). `scripts/verify-catalog.ps1` and this catalogue note were not updated
  at the time; both are brought current in PR #20 below.
- `20260912000000_tester_feedback_round_2.sql` (**applied 2026-09-01**): KUT's
  tester feedback round 2 (ADR-044), one migration for four defects + three
  ideas. **Data-changing tier (ADR-032)** solely for a scoped, reversible
  backfill of existing `bibs_bonus` `kut.user_notifications` bodies ("washing
  the bibs after" → "bringing the bibs to"); the rest is additive —
  `create or replace kut.grant_bibs_reward` (same body, one string changed),
  new `kut.set_own_club_name(text)` self-service RPC writing the dormant
  `kut.profiles.club_name` column, `create or replace kut.club_value_leaderboard`
  to `coalesce` that column with the synthesised `"<name>'s Club"` default (no
  `club_value` / `rank` change), and a new additive `kut.published_sessions`
  summary view. Fresh encrypted backup immediately before the push; full
  reverse DDL in the migration header. Pushed from this repo 2026-09-01 after
  KUT PR #31 + catalogue PR #20 merged; `migration list --linked` shows
  `20260912000000` Local = Remote with no drift on the 44 prior migrations.

## Repo status

- Branch protection on `main` enabled 2026-08-23 (squash-only merges, PRs
  required, direct pushes blocked including for admins). See the global
  `~/.claude/CLAUDE.md` "Branch workflow" section for the actual branch/PR
  conventions to follow.
