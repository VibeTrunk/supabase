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
