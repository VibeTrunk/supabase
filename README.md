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
`20260829000000_august_2026_full_month_roster_and_sessions.sql`. Cogitster's
pending `202608160002_lock_down_trigger_execute.sql` is intentionally absent
until its own release is approved.

- `20260818000000_initial_tfh_roster_and_august_sessions.sql` (applied
  2026-08-18): the first real TFH roster/attendance data, and the reweighted
  activity rating formula from KUT's ADR-024.
- `20260829000000_august_2026_full_month_roster_and_sessions.sql` (applied
  2026-08-29): the two remaining August 2026 sessions (21.08, 28.08) and four
  players who reached 2+ appearances (Steffen, Serhat, Stephen, Maarten).
