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
- `20260913000000_chronicle_views.sql` (**applied 2026-09-02**): KUT's TFH
  Chronicle read projections (ADR-049). **Additive tier (ADR-032)** — two
  computed views and their grants, no data change, no existing object
  rewritten. `kut.chronicle_weeks` aggregates published `kut.match_sessions` +
  `kut.attendance` into one row per football week; `kut.chronicle_tier_changes`
  runs a `lag()` over `kut.player_rating_snapshots` for consecutive weeks where
  a player's rarity tier differs. Both `security_invoker = true,
  security_barrier = true` (every underlying select is already permitted to
  members), `revoke all from public`, `grant select to authenticated,
  service_role`. Rode the last scheduled backup per the additive tier; reverse
  DDL is two `drop view`s, in the migration header. Catalogued in PR #22 and
  pushed from this repo 2026-09-02 after KUT PR #36 merged; `migration list
  --linked` shows `20260913000000` Local = Remote with no drift on the 45 prior
  migrations.
- `20260914000000_admin_self_wallet_grant.sql` (**applied 2026-09-04**): KUT's
  ADR-052. A second, superadmin-only coin faucet, `kut.admin_grant_self_wallet(bigint,
  text, uuid)`, that targets the caller's own wallet (`auth.uid()`) rather than
  an arbitrary `p_user_id`. `kut.admin_adjust_wallet` (ADR-035) keeps refusing
  to touch the caller's own wallet for every role, including superadmin — that
  guard is untouched; this is a separate function with its own audit tags
  (`wallet_ledger.reason 'admin_self_grant'`, `admin_account_events.action
  'self_wallet_grant'`) so a self-grant is never indistinguishable from an
  admin crediting a member. Same guards as `admin_adjust_wallet` (`abs` cap
  100000, never below zero, 1–200 char reason), plus a real
  `p_idempotency_key` backed by a partial unique index — closing a gap
  `admin_adjust_wallet` itself has. **Additive tier (ADR-032)**: one
  `create or replace function`, two widened check constraints
  (`admin_account_events.action`, `wallet_ledger.reason`), one new partial
  index; nothing existing is rewritten or dropped, no data migration, so it
  rode the last scheduled backup (2026-09-02). Reverse DDL in the migration
  header. Catalogued in PR #24 and pushed from this repo 2026-09-04 after KUT
  PR #43 + catalogue PR #24 merged; `migration list --linked` shows
  `20260914000000` Local = Remote with no drift on the 46 prior migrations. A
  hosted `kut` schema dump confirms `kut.admin_grant_self_wallet`, the two
  widened check constraints, and `admin_account_events_self_grant_idem_idx`
  all present.
- `20260915000000_activity_feed_excludes_superadmin.sql` (**applied
  2026-09-05**): KUT's ADR-054, KB-009. `create or replace view
  kut.activity_feed` adds a `role <> 'superadmin'` guard on whichever
  profile(s) generated each row — seller and buyer for a `sale`, seller and
  proposer for a `trade`, seller for a `listing`, opener for a `pack`. The
  `session` branch is untouched, since a published session isn't one
  member's economic activity. Fixes the production superadmin demo/test
  account's own pack opens, sales, listings and trades showing up in the
  member-facing club activity feed on Home. **Additive tier (ADR-032)**: one
  `create or replace view`, same columns, no table, grant, or RLS change on
  the underlying `market_sales` / `trade_offers` / `market_listings` /
  `pack_openings` — their ledger and audit history are fully retained, only
  this read projection is narrower; rode the last scheduled backup, no fresh
  pre-push backup required. Reverse DDL (restore the pre-guard view body) is
  in the migration header. Catalogued in PR #26 and pushed from this repo
  2026-09-05 after KUT PR #59 + catalogue PR #26 merged; `migration list
  --linked` shows `20260915000000` Local = Remote with no drift on the 47
  prior migrations. A hosted `kut` schema dump confirms
  `kut.activity_feed`'s `sale` / `trade` / `listing` / `pack` branches all
  carry the `role <> 'superadmin'` guard, with both grants to `authenticated`
  and `service_role` intact.
- `20260922000000_kudos_cap_two_and_award_notice.sql` (**applied
  2026-09-07**): KUT's ADR-063. Raises the
  kudos half of rating v2. The qualified-kudos Form ladder becomes
  `0 / 1 / 1.5 / 2` for `0 / 1 / 2 / 3` recognised categories (was
  `0 / 1 / 1.25 / 1.5`); the combined per-session Form input cap rises
  `3 → 3.5` (`kut.session_report_results.session_input` `check` dropped by
  `pg_get_constraintdef` lookup and re-added as
  `session_report_results_session_input_check` = `0..3.5`); goals still cap at
  1.5 and the v2 Form ceiling stays 8. `kut.user_notifications.event_type`
  gains `kudos_awarded` (same drop-by-lookup and re-add of
  `user_notifications_event_type_check`). `create or replace
  kut._finalize_one_session` — the new ladder, `least(3.5, goal_form +
  kudos_form)`, a `jsonb_object_agg` snapshot of every player's
  `kut.player_season_state.live_ovr` taken *before* `kut._rebuild_season_core`,
  and one extra insert: for each attendee with
  `cardinality(qualified_category_ids) > 0`, a `kudos_awarded`
  `kut.user_notifications` row that never names a nominator and states the
  player's OVR movement from finalising that session (goals + kudos), or no
  number when it is `<= 0`. Idempotent on
  `(user_id, event_type, reference_type, reference_id)` and sent alongside the
  existing club-wide `session_results` notice, so an admin goal correction that
  re-finalises neither resends nor restates it. **Data-changing tier
  (ADR-032)**: a scoped `update kut.session_report_results` re-scores existing
  derived result rows to the new ladder/cap, then a `do $$` loop replays every
  affected season through `kut._rebuild_season_core`. Raw reports, ballots,
  `session_report_rewards`, `wallet_ledger`, transactions and `session_surveys`
  audit timestamps are untouched; historical finalised sessions emit no
  `kudos_awarded`. A fresh encrypted `kut`-schema backup was taken immediately
  before the push. Reverse DDL in the migration header restores the `0..3`
  check, drops `kudos_awarded` from the event_type check, restores the prior
  `_finalize_one_session` body (`… when 2 then 1.25 else 1.5`, `least(3, …)`,
  no OVR snapshot or notice), and re-scores + replays. Catalogued in PR #29
  and pushed from this repo 2026-09-07 after KUT PR #65 + catalogue PR #29
  merged; `migration list --linked` shows `20260922000000` Local = Remote with
  no drift on the prior migrations. Hosted checks confirm
  `session_report_results_session_input_check` is
  `CHECK ((session_input >= 0) AND (session_input <= 3.5))`,
  `user_notifications_event_type_check` lists `kudos_awarded`, and
  `pg_get_functiondef('kut._finalize_one_session(uuid)')` carries the
  `0 / 1 / 1.5 / 2` ladder, `least(3.5, …)` and the `kudos_awarded` insert.
  `kut.session_report_results` is empty on hosted (no v2 survey finalised yet),
  so the re-score `update` and the season replay touched zero rows.

- `20260923000000_chronicle_results_visibility.sql` (**applied 2026-09-08**):
  KUT's ADR-066, additive. Fixes a live read blackout: the Chronicle's
  finalized per-player results were readable only by that session's attendees
  and admins, so every member who missed the session saw "Results finalized. No
  report results were recorded." while an admin on the same URL saw the full
  table. `kut.chronicle_session_reports` ran with `security_invoker=true` and
  inner-joins `kut.session_surveys`, whose `"eligible members read surveys"`
  policy admits only `kut.is_admin()` or a member holding a
  `kut.session_survey_eligibility` row. The `"members read finalized results"`
  policy on `kut.session_report_results` failed identically, because Postgres
  applies a referenced table's RLS inside a policy expression, so its `exists()`
  over `session_surveys` was blind too. `create or replace view` flips the
  projection to `security_invoker=false`, matching its sibling
  `kut.chronicle_session_report_status` (`20260920090000`), and the policy is
  dropped and recreated over a new `security definer`
  `kut.is_survey_finalized(uuid)` (`revoke` from `public`/`anon`, `grant` to
  `authenticated`/`service_role`). Side effect: `submitted_reports`,
  `eligible_accounts` and `attendee_count` — sub-selects over RLS-scoped tables
  that made an attendee compute "1 of 1 reports submitted" — now report
  club-wide counts. **Additive tier (ADR-032)**: no `update`, no backfill, no
  season replay; the 7 September survey was already finalized, so this changed
  what members may read, not any stored result. No new disclosure —
  `effective_goals` is already club-wide as
  `chronicle_session_report_status.goal_total`, `recognized_categories` lists
  only categories two or more nominators agreed on, and `goal_form` /
  `kudos_form` / `session_input` are pure functions of those two under ADR-063.
  The join on `status='finalized'` is now the only guard keeping an open session
  out of the projection. Reverse DDL in the migration header restores the
  invoker view and the inline-`exists()` policy and drops the function, which
  reinstates the blackout. Catalogued in PR #31 and pushed from this repo
  2026-09-08 after KUT PR #69 + #70 and catalogue PR #31 merged. Hosted checks
  confirm `chronicle_session_reports` reports `security_invoker` = `false` and
  `kut.is_survey_finalized` exists.
- `20260924000000_admin_finalize_session_survey.sql` (**applied 2026-09-08**):
  KUT's ADR-067, additive. Lets an admin close a session's report window before
  its 24 hours elapse instead of waiting for the deadline and the ADR-061 lazy
  fallback. `kut.session_surveys` gains nullable `finalized_by` (references
  `kut.profiles(id) on delete restrict`) and `finalized_reason` (`check` 3–500
  chars when present); `kut.admin_finalize_session_survey(uuid, text)` is a
  `security definer` front door to the existing `kut._finalize_one_session`, so
  scoring, `kut._rebuild_season_core` and the `session_results` /
  `kudos_awarded` notifications are unchanged — only the timing moves. Gated on
  `kut.is_admin()`, requires a 3–500 character reason, refuses a cancelled
  survey, returns `already_finalized` rather than raising on a second press, and
  returns the attendee / eligible / submitted counts plus whether the
  three-ballot kudos quorum was met. `closes_at` is deliberately not moved: the
  table's `check (closes_at = opened_at + interval '24 hours')` would force
  rewriting `opened_at` and erase when the window opened, so the published
  deadline stands and an early close reads as `finalized_at < closes_at`. Both
  audit columns stay null on the automatic path and on the re-finalization
  `kut.admin_correct_session_goals` triggers, so null means "closed at its
  deadline". Nothing downstream needed changing — every consumer already keys
  off `session_surveys.status`. **Additive tier (ADR-032)**: no data change;
  every existing survey row takes `finalized_by = null`. A member who had not
  submitted when an admin closes the window loses the window and the 50-coin
  completion reward; rewards already earned are untouched. Reverse DDL in the
  migration header drops the function and both columns. Catalogued in PR #31 and
  pushed from this repo 2026-09-08 in the same `db push` as
  `20260923000000`. Hosted checks confirm both columns exist and are nullable,
  `kut.admin_finalize_session_survey` exists, and
  `select count(*) from kut.session_surveys where finalized_by is not null`
  returns 0.
- `20260925000000_kudos_award_notice_detail.sql` (**applied 2026-09-08**):
  KUT's ADR-069. Text-only follow-up to `20260922000000`'s `kudos_awarded`
  notice, which read "Teammates recognized you with kudos this session. Your
  card rating rose +N OVR this week." — it named none of the categories the
  player was actually recognised in, and implied the whole week's movement came
  from kudos. New immutable `kut._join_names(text[])` renders a name list as
  `A`, `A and B` or `A, B and C` (`revoke all from public, anon`; execute to
  `service_role` only — it is called from inside a `security definer` function,
  never by the browser). `create or replace kut._finalize_one_session` — same
  scoring, same `kut._rebuild_season_core`, same pre-rebuild `live_ovr`
  snapshot, same `session_results` notice, same idempotency key. Only the
  `kudos_awarded` body changes: it now names every recognised category ordered
  by `array_position(v_survey.category_ids, c.id)` — ballot order, so the notice
  lists them the way the member saw them, not `category_id` order — and
  attributes the movement to this session's goals *and* kudos, naming the goal
  count from `session_report_results.effective_goals` when it is `> 0` ("Your 2
  goals and these kudos lifted your card rating +3 OVR this week", "Your 1
  goal…") and claiming no goals when it is not ("These kudos lifted…"). A
  movement of `<= 0` still yields no rating sentence, and the notice still names
  no nominator. Attributing the finalisation delta to goals + kudos is accurate:
  appearances were already counted when the session was published, so the report
  results are the only new input at finalisation. **Additive tier (ADR-032)**:
  one new function plus one `create or replace`; no table, constraint, grant,
  scoring rule or rating-maths change, and no DML. Notices already written keep
  the ADR-063 wording — re-finalising hits the existing `on conflict
  (user_id, event_type, reference_type, reference_id) do nothing` — so the club
  sees a mix until the next session finalises, which was preferred over
  rewriting notices members had already read. Relied on the most recent
  scheduled backup (`20260908-215210`) rather than a fresh one, per the additive
  tier. Reverse DDL in the migration header: drop `kut._join_names(text[])`,
  then re-run the `create or replace function kut._finalize_one_session` block
  from `20260922000000_kudos_cap_two_and_award_notice.sql`. Catalogued and
  pushed from this repo 2026-09-08. `migration list --linked` shows
  `20260925000000` Local = Remote with no drift across the ledger, and the
  catalogue check reports 65 approved source migrations.
- `20260926000000_trade_log_rating_story_listing_duration.sql` (**applied
  2026-09-16**): KUT's ADR-072 + ADR-073 + ADR-074, shipped in
  one file. **Three features in one migration is deliberate and exceptional** —
  KUT's own convention is one migration-bearing feature per PR, and its
  `migrations` CI job enforces at most one added migration file per change. The
  owner instructed the batch on 2026-09-16 so the hosted schema is pushed once
  rather than three times; KUT's ADR-075 records the reasoning, that the
  file-count invariant is satisfied honestly rather than circumvented, and that
  it sets no precedent. Each section is an independently reviewable slice with
  its own ADR, its own database test file and its own reverse DDL, and the three
  touch disjoint objects, so no section can mask a defect in another. Postgres
  DDL being transactional, a failure anywhere rolls the whole file back — which
  is why one push is safer here than three sequential ones, not merely quicker.
  **Zero DML**: no `insert`, `update` or `delete` against member data anywhere
  in the file, no table created or altered, no backfill, and no economy or
  rating formula changed. Every input the three features read already existed
  and was simply never projected.
  - **Section 1 (ADR-072)** — a seller chooses a 24- or 72-hour listing.
    `kut.market_listings.expires_at` has carried
    `default (now() + interval '24 hours')` since `20260816070600`, and expiry
    has always been enforced lazily by the `expires_at > now()` predicates in
    the table's RLS policy, `kut.active_market_listings`,
    `kut.my_collection_cards`, `kut.activity_feed`, `kut.buy_listing`,
    `kut.propose_trade` and `kut.prevent_burning_listed_card`, plus the
    opportunistic self-heal in `create_listing`/`buy_listing`. None of that
    moves; only the value written at insert time does, and the column default
    stays 24h. `drop function if exists kut.create_listing(uuid, bigint)` comes
    **first and is load-bearing**: a defaulted third parameter creates an
    *overload*, not a replacement, which would have left the two-argument entry
    point alive and permanently 24-hour. The new parameter defaults to 24, so
    existing two-argument callers stay valid. Body rebased on the current
    `20260911000000_trade_offers.sql` definition so the ADR-042
    `held_by_offer_id` escrow guard survives. Duration is an allow-list
    (`not in (24, 72)`, with `null` checked explicitly), dual-declared with
    `ECONOMY.listingDurationChoiceHours` in the KUT repo. The insert now names
    `expires_at` and uses `returning` instead of the previous hardcoded
    `now() + interval '24 hours'` in the return payload, which was never read
    back from the row.
  - **Section 2 (ADR-073)** — `create or replace view kut.activity_feed` so an
    accepted trade reports its whole consideration. Two fixes. The trade branch
    reported `trade_offers.coins_to_seller` while every other branch reports
    gross (`market_sales.sale_price`, `market_listings.price`,
    `pack_openings.price_paid`); it now reports `trade_offers.offered_coins`, so
    `amount` means the same thing in all five branches. **Existing trades will
    therefore display ~5% higher after this is applied** — no row is rewritten,
    `coins_to_seller` and `coins_burned` are untouched, and the seller still
    sees the real post-burn receipt on `/market/offers`; the feed simply reports
    the price rather than the proceeds. Second, `kut.trade_offer_cards` was
    never joined, so cards moving the other way were invisible; a `left join
    lateral` `array_agg` now supplies them in a new **ninth column**
    `offered_card_names text[]`, appended last because `create or replace view`
    can only append (the same constraint `20260909000000` met) — all five
    branches carry it, four as `null::text[]`. `left join`, not `cross join`, so
    a coins-only trade still yields a row with `null` rather than an empty
    array. Stays `security_invoker = false`, so the new join raises no RLS
    question; both `role <> 'superadmin'` guards (ADR-054 / KB-009) are
    unchanged, and the branch still does not reference `kut.market_sales`, so
    KUT Part L invariant #23 holds.
  - **Section 3 (ADR-074)** — two new read projections behind a "why this
    rating" story: `kut.player_rating_breakdown` and
    `kut.player_form_contributions`, both
    `security_invoker = true, security_barrier = true`,
    `revoke all from public`, `grant select to authenticated, service_role`.
    Invoker rights are deliberate and the opposite of section 2: they make the
    caller's own RLS apply, so `kut.session_report_results` stays gated to
    finalized surveys by `kut.is_survey_finalized` (ADR-066). Definer views
    would have bypassed that gate and exposed unfinalized results. The OVR split
    is *derived, not recomputed*: `form_bonus` is `floor(form_score + 0.5)`, the
    engine's own final rounding, and `attendance_base` is `live_ovr` minus that,
    so the halves reconstruct the stored `live_ovr` by construction rather than
    risking an off-by-one against a re-evaluated
    `30 + 45*(activity/100)^0.8`; `is_ovr_capped` flags the 83 clamp.
    `player_form_contributions` mirrors the session-age decay ladder
    (1 / .75 / .5 / .25 / 0) and the `(session_date, session_type, id)` tuple
    ordering from `kut._rebuild_season_core`. **That duplication is the one
    maintenance hazard in this file** — change the ladder in the engine without
    changing the view and the view lies silently — and it is pinned by
    `rating_breakdown.test.sql`, which runs the real `_rebuild_season_core` over
    a fixture and asserts the summed `weighted_contribution` equals the
    resulting `player_season_state.form_score`. Neither view may join
    `kut.session_kudos` (nominator identity) or `kut.session_surveys` (whose
    attendee-only policy caused the KB-013 blackout); a test asserts this via
    `information_schema.view_table_usage` rather than trusting review.
  - **Additive tier (ADR-032)**: relies on the most recent scheduled backup
    rather than a fresh pre-push one; no restore drill. Reverse DDL is in the
    migration header, per section: drop
    `kut.create_listing(uuid, bigint, integer)` and recreate the two-argument
    version from `20260911000000_trade_offers.sql`; re-run the view body from
    `20260915000000_activity_feed_excludes_superadmin.sql`; and drop both new
    views, which nothing else references. Section 2's rollback restores the
    eight-column shape, so application code selecting `offered_card_names` must
    be reverted with it.
  - **Sequencing note.** KUT's KB-017 (2026-09-16 Supabase Security Advisor
    review) names `kut.activity_feed` among the definer projections that grant
    `SELECT` to `authenticated` without proving an active KUT profile. This
    migration neither causes nor worsens that finding — the view already had
    those properties — but whoever fixes KB-017 **must rebase on this version of
    the view**, or they will silently revert the gross-coins fix and drop the
    ninth column.
  - Merged as KUT PR #86 (`aa1f254`); KUT CI green on `migrations`, `database`,
    `e2e`, `fast`, `merge-gate`, `security` and `scan`. Catalogue check reports
    66 approved source migrations.
  - Catalogued via PR #34 and pushed from this repo 2026-09-16, on a fresh
    cold-verified backup (`20260916-005721`) taken minutes before rather than
    the scheduled one the additive tier would have allowed. Smoke-tested on
    hosted immediately after: a card lists for 72 hours and shows its real
    expiry date, the club activity feed returns rows again, and a Live card
    renders its rating buildup.
  - **Ordering note for the future.** KUT's Vercel production deploy fires on
    merge to its `main`, so merging PR #86 shipped application code that
    expected this schema **before** the schema existed. For roughly two hours
    creating a market listing failed on hosted — `create_listing` was called
    with `p_duration_hours` against the old two-argument signature — and the
    club activity feed rendered empty, because selecting the not-yet-existing
    `offered_card_names` errored and that widget is deliberately non-critical.
    Nothing crashed and no data was at risk, but the lesson generalises: when a
    tool's app deploy is coupled to its own merge, the catalogue push should be
    ready to follow immediately, or the app change should tolerate the old
    schema. Worth considering a feature flag or a tolerant read for the next
    migration whose code cannot degrade as gracefully as this one did.

- `20260927000000_session_report_status_is_monotonic.sql` (**applied
  2026-09-22**): KUT's ADR-078, fixing KB-020. Merged in KUT PR #91
  (`9f43c41`). A member who had already
  submitted a session report could press "Save draft" and silently move their
  own report back to `draft`, while `kut.session_report_rewards` — written once
  on the original submit and never deleted — kept the 50-coin reward. The admin
  roster joins the two independently and displayed exactly that: "Draft ·
  Reward paid".
  **Not cosmetic.** `kut._finalize_one_session` scores only `status='submitted'`
  rows and uses the same filter for the `v_turnout>=3` gate that decides whether
  any kudos are recognised in a session, so a report left in this state at
  finalization drops that member's goals and kudos and can wipe kudos
  recognition for everyone present — while their `kut.session_kudos` rows still
  count toward recipients' two-nominator threshold.
  **DDL**: one `create or replace function kut.submit_session_report`. The body
  is the `20260920000000` original with one new local, `v_intent`, derived from
  the stored row before any validation runs, plus its five uses. No table
  created or altered, no constraint, grant or trigger changed, no economy or
  rating formula touched. A guard inside the `on conflict do update` was
  rejected: it would hold the status while letting the row be rewritten under
  the weaker draft validation, leaving a submitted report with a null goal
  count or an incomplete ballot.
  **DML, and this is the data-changing part**: one scoped `update` repairing
  rows where `status='draft'` sits beside a `kut.session_report_rewards` row.
  That combination is reachable by no other path — a reward row is written only
  by a real submit and is never deleted — so the predicate is exact.
  `submitted_at` is recovered from `updated_at`, the closest surviving evidence.
  **Deliberately not replayed**: sessions already finalized with a regressed
  report are *not* re-scored, although `kut._finalize_one_session` is
  re-runnable and `kut.admin_correct_session_goals` calls it exactly that way.
  Owner decision, 2026-09-22: replaying would move live OVR for real members
  retroactively, push `finalized_at` forward and disturb the ADR-067 reading of
  `finalized_at < closes_at` as "closed early". The consequence is that for an
  already-finalized session those goals and kudos stay out of that week's
  scoring. A later `admin_correct_session_goals` on such a session re-scores it
  correctly.
  **Tier: data-changing.** Needs a fresh cold-verified backup before the push,
  not the scheduled one — the same treatment ADR-063 had.
  **Reverse DDL** in the migration header: re-emit the pre-KB-020 body of
  `kut.submit_session_report` verbatim from
  `20260920000000_session_reports_rating_v2.sql:242-308` as
  `create or replace function`. The backfill is **not** reversible: nothing
  records which rows were draft beforehand, so a repaired row cannot afterwards
  be told apart from one submitted normally.
  Verified in the KUT repository: 16 pgTAP assertions in
  `supabase/tests/database/session_report_status.test.sql`, run against the old
  function body as a negative control where five of them fail — including the
  standing invariant that no report is left as a draft while holding a
  completion reward.
  **Pushed 2026-09-22** on a fresh cold-verified backup, `20260922-204443`
  (plaintext SHA-256 `176C33C3E4DCEBB2FDFFF9D67FAEA60E0528722BCF7B6C45A296FDAC295240F6`,
  cold verification passed in a separate process at 18:45:13Z). The data-changing
  tier earned that fresh backup even though the DML turned out to be a no-op --
  see below -- because the tier follows what the file *can* do, not what it
  happens to do on the day.
  **The backfill matched zero rows.** Both reconnaissance queries run against
  hosted before the push returned nothing: no `session_reports` row sat at
  `status='draft'` beside a `session_report_rewards` row, and no survey was
  open. The originally reported "Draft - Reward paid" row had evidently been
  re-submitted in the meantime, which restores the status and leaves the reward
  alone. So on hosted this migration is **preventive, not corrective**: it closed
  the path rather than repairing damage, and no already-finalized session needed
  the replay that was deliberately declined. The join in the reconnaissance query
  could not have hidden a row -- `session_reports.session_id` and `player_id` are
  both `not null` with `on delete restrict` foreign keys.
  After the push, `migration list --linked` shows 67 entries with none pending and
  no remote-only drift, `20260927000000` Local = Remote, and the catalogue check
  reports 67 approved source migrations. Smoke-tested on hosted: the deployed
  function body contains `v_intent` (`prosrc like '%v_intent%'` is true), so the
  fix is in the running definition and not merely in the ledger, and the standing
  invariant still counts zero reports left at `draft` while holding a completion
  reward. The end-to-end check &mdash; submit, then confirm the RPC refuses a
  draft &mdash; waits for the next published session, since no survey was open.
- `20260928000000_active_member_projection_gate.sql` (**applied 2026-09-22**):
  KUT's ADR-079, merged in KUT PR #92 (`84de167`), closing KB-017 — a Supabase Security Advisor
  finding. Ten `security_invoker = false` views in the `kut` schema grant
  `SELECT` to this project's shared `authenticated` role and deliberately
  bypass their source tables' RLS, but none proved the caller is a KUT member.
  **This is the cross-tool boundary that matters for a shared project**: a JWT
  issued by another VibeTrunk tool is `authenticated` here too, so it could
  read member-only names, market and activity data, Club Values, ratings and
  Chronicle results through the Data API, as could a disabled KUT account with
  a still-valid session. A bounded read disclosure — these are read
  projections and `anon` has no `SELECT` on any of them.
  **DDL**: one new `kut.is_active_member()` (`sql`, `stable`,
  `security definer`, `search_path = kut, pg_catalog`, execute revoked from
  `public`/`anon` and granted to `authenticated`/`service_role`) plus ten
  `create or replace view`. `security definer` is required because
  `kut.profiles` RLS lets a member read only their own row, so invoker rights
  could never prove a *foreign* caller has no profile.
  **Zero DML**: no table created, altered or written, no backfill, no grant
  change — the grants in the file re-assert what each source migration already
  granted.
  **Nothing is flipped to `security_invoker = true`.** That is the Advisor's
  generic remedy and it is wrong for these views: they are cross-RLS club
  projections by design, and doing it to `kut.chronicle_session_reports` is
  precisely KUT's KB-013, the live Chronicle blackout of 2026-09-08.
  **Shape**: each view body is copied byte-identically from its source
  migration and wrapped as
  `select * from ( <body> ) gated where kut.is_active_member()`. The risk in
  this migration is transcription across ten bodies and six source files, not
  semantics, and the wrapper also makes it structurally impossible for
  `create or replace view` to change a column's name, order or type, since
  `select *` is expanded from an unchanged body. `EXPLAIN` shows
  `One-Time Filter: kut.is_active_member()`, so a denied caller never executes
  the body.
  `kut.public_live_ratings` additionally gains the explicit
  `security_invoker = false` it previously only inherited as the default.
  **Tier: additive, projection-only.** Rides the most recent scheduled backup.
  Must be its own push, separate from the data-changing `20260927000000`.
  **Reverse DDL** in the migration header: re-emit the ten bodies without the
  wrapper as `create or replace view` — never `drop view`, because
  `kut.my_club_value` depends on `kut.my_club_value_editions` — then
  `drop function kut.is_active_member();`. Grants are unchanged, so none need
  re-granting.
  **Operator note**: `kut.is_active_member()` is false for a bare psql session
  with no JWT and no `SET ROLE`. An ad-hoc query against any of these ten views
  from this repository's tooling needs `set role service_role;` first, or it
  will read zero rows and look like data loss when there is none.
  Verified in the KUT repository: 71 pgTAP assertions in
  `supabase/tests/database/member_only_projections.test.sql` covering `anon`, a
  profileless JWT, a disabled member, an active participant, an active
  bystander and `service_role` across all ten views. Run against the ungated
  views as a negative control it fails 15 of them, matching KB-017's own
  accounting exactly.
  **Pushed 2026-09-22**, second of two separate pushes that evening and the
  additive one, so it rode the backup taken for `20260927000000`
  (`20260922-204443`) rather than a fresh one. Afterwards
  `migration list --linked` shows 68 entries with none pending and no
  remote-only drift, both `20260927000000` and `20260928000000` Local =
  Remote, and the catalogue check reports 68 approved source migrations.
  **Smoke-tested from the app as an ordinary member, which is the only test
  that matters here**: this migration's failure mode is not an error but an
  empty screen, exactly how KB-013 blacked out the Chronicle. Home (activity
  feed, Club Value, leaderboard), `/market`, `/leaderboard`, `/club/value`,
  `/market/offers` and a finalized Chronicle issue all rendered populated.
  Direct reads under `set role service_role` returned 21 rows from
  `kut.activity_feed` and 66 from `kut.chronicle_session_reports`, the latter
  consistent with three finalized surveys across the roster &mdash; so the
  cross-RLS projection the KB-013 fix restored is still whole.
- `20260929000000_season_rating_rules_rls.sql` (**applied 2026-09-23**):
  KUT's ADR-081, merged in KUT PR #98 (`25274ce`). This is the last
  open item from the 2026-09-16 Supabase Security Advisor review.
  `kut.season_rating_rules` (one row per season, its rating-v2 cutover week) was
  the only table in the `kut` schema with RLS disabled. It was not a write or
  integrity hole: `20260920070000` already grants only `SELECT`, to
  `authenticated` and `service_role`, and nothing to `anon`. But on this shared
  project a JWT issued by another VibeTrunk tool, or a disabled KUT account with
  a still-valid session, could read the cutover dates. That is the same
  cross-tool boundary as `20260928000000`, drawn with the same predicate.
  **DDL**: `alter table … enable row level security` plus one policy,
  `"active members read rating rules"`: `for select to authenticated using
  (kut.is_active_member())`. There is no write policy and no grant change, so
  writes stay refused by the missing grant with `42501`. The policy filters
  rather than raises. KUT's `/admin/attendance`, the one app reader, runs as an
  authenticated admin and passes it, and the service role has `BYPASSRLS`.
  **Zero DML.**
  **No `FORCE`.** The three `security definer` readers and writers are
  `kut._rebuild_season_core`, the `match_sessions_rating_version` trigger and
  the `seasons_initialize_rating_rules` trigger. They are owned by the table's
  owner and keep working through the owner bypass. Measured locally, `FORCE`
  would not break them either, because `postgres` carries `BYPASSRLS`. It is
  left off because it buys nothing and would rest those paths on a platform role
  attribute instead of on ownership.
  **Tier: additive, access-only.** Rides the most recent scheduled backup.
  **Reverse DDL** in the migration header:
  `drop policy "active members read rating rules" on kut.season_rating_rules;
  alter table kut.season_rating_rules disable row level security;`. Grants are
  unchanged, so none need re-granting.
  Verified in the KUT repository: 27 pgTAP assertions in
  `supabase/tests/database/season_rating_rules_rls.test.sql`, covering `anon`, a
  profileless JWT, a disabled member, an active member, an admin, the service
  role, member writes, the three definer paths, and "no `kut` table has RLS
  disabled". Against the unmigrated schema, 7 of them fail as a negative
  control. After the migration the full KUT suite passes: 20 files, 630
  assertions.
  **Hosted smoke test after the push**: as an admin, `/admin/attendance` still
  explains the reporting cutover, and the next session still publishes and
  finalizes normally. The failure mode to watch for is silent: a denied read
  returns zero rows, not an error.
  **Pushed 2026-09-23** from this repository, on its own `db push`, after
  catalogue PR #40 merged and this checkout was pulled to `c585c14`. Additive,
  so it rode the latest scheduled backup, `20260922-214356`, cold-verified.
  Before the push, `migration list --linked` showed 68 entries with
  `20260929000000` the only local-only one and no remote-only drift, the dry run
  named exactly that file, and the catalogue check reported 69 approved source
  migrations. Afterwards `migration list --linked` shows 69 entries, all present
  locally and remotely, with `20260929000000` on both sides.
  **Smoke-tested on hosted.** In the SQL editor: `relrowsecurity = true`,
  `relforcerowsecurity = false`, the one policy exactly as written, and grants
  unchanged (`SELECT` for `authenticated` and `service_role`, nothing for
  `anon`). The schema-wide check returned no `kut` table without RLS. In the
  app, a superadmin on `/admin/attendance` still sees "This date uses member
  reports" for a post-cutover date. The page falls back to the admin-goals
  wording when the cutover is missing, so that is proof the admin read the row
  through the new policy, not merely the absence of an error. The remaining
  check, that the next session publishes and finalizes normally, waits for a
  real session.

- `20260930000000_injury_protection.sql` (**applied 2026-09-23**):
  KUT's ADR-082, merged in KUT PR #100 (`efa14df`). **Injury mode.** An admin
  puts a Player with an active account into injury mode. Each football week the
  Player sits out, the member does a rehab check-in: +100 KUT Coins, and that
  week's Activity carries over instead of decaying &times;0.90. Form still
  fades. Injury mode ends by itself when the Player attends a published session
  dated after the injury date. Protection is never backdated.
  **DDL**: tables `kut.injury_periods` (admin-read only; the note may hold
  medical detail) and `kut.injury_check_ins` (primary key
  `(player_id, week_start)`, the stipend's idempotency guard and the only fact
  the rebuild reads). Functions `kut._active_injury_period`,
  `kut._injury_checkable_week` (service role only), `kut.admin_start_injury`,
  `kut.admin_end_injury`, `kut.my_injury_status`, `kut.injury_check_in`. View
  `kut.injured_players` (definer, gated on `kut.is_active_member()`, never
  exposes the note). An `after update of status` trigger on
  `kut.match_sessions` sends an `injury_check_in` notice. `wallet_ledger`
  reasons gain `injury_stipend`, and `user_notifications` event types gain
  `injury_check_in`.
  **`kut._rebuild_season_core` is re-emitted** verbatim from `20260920000000`
  plus one protected-week guard. Rebuilding KUT's local data before and after
  gave zero differences in 29 players and 174 snapshots: output only changes
  once a check-in row exists.
  **Zero DML.**
  **Tier: data-changing.** It adds a new `wallet_ledger` reason and changes the
  rating engine, so it needs a fresh, cold-verified backup before the push.
  **Reverse DDL** is in the migration header. It drops the trigger, view,
  functions and both tables, re-runs the `20260920000000` rebuild body, and
  narrows both check constraints after deleting any rows that use the new
  values.
  Verified in the KUT repository: 48 pgTAP assertions in
  `supabase/tests/database/injury_protection.test.sql`. The full KUT suite
  passes: 21 files, 678 assertions. There was also a manual end-to-end pass on
  the local stack.
  **Hosted smoke test after the push**: the new objects exist and the ledger
  and notification constraints carry the new values; `kut.injured_players`
  returns zero rows (nobody is injured yet); and KUT's `/admin/roster` shows
  the Injury column.
  **Pushed 2026-09-23** from this repository, on its own `db push`, after
  catalogue PR #42 merged and this checkout was pulled to `304a618`.
  Data-changing, so it was preceded by a fresh backup,
  `20260923-105756`, cold-verified, with 0 escrowed cards. Before the push,
  `migration list --linked` showed 70 entries with `20260930000000` the only
  local-only one and no remote-only drift, the dry run named exactly that file,
  and the catalogue check reported 70 approved source migrations. Afterwards
  `migration list --linked` shows 70 entries, all present locally and remotely.
  **Smoke-tested on hosted.** In the SQL editor, one row confirmed: both tables
  with RLS on, all six functions, the view and the trigger, `injury_stipend` and
  `injury_check_in` in their check constraints, the protected-week guard in
  `kut._rebuild_season_core`, no execute for `anon` on `kut.injury_check_in`,
  and zero injury periods. In the app, `/admin/roster` shows the Injury column
  and Home renders normally.

## Repo status

- Branch protection on `main` enabled 2026-08-23 (squash-only merges, PRs
  required, direct pushes blocked including for admins). See the global
  `~/.claude/CLAUDE.md` "Branch workflow" section for the actual branch/PR
  conventions to follow.
