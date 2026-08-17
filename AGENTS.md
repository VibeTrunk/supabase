# AGENTS.md

Read `CLAUDE.md` before changing this repository.

This repository is the only deployment authority for the shared VibeTrunk
Supabase project. Never run `supabase db push`, `supabase migration repair`,
or other live database mutations from an individual tool repository.

Every shared-database change needs a reviewed migration here and a matching
copy in the owning app repository for that app's local test stack. Never
delete, rename, or edit an applied migration. Do not store credentials,
database exports, or production data in this repository.
