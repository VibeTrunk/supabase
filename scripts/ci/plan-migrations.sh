#!/usr/bin/env bash
# Writes the migrations `supabase db push` would apply to <plan-file>, one
# "<file> <sha256>" line each, and refuses any that is not a KUT migration.
# A KUT migration has a byte-identical copy in the given VibeTrunk/kut
# migrations directory; other tools' migrations need their own route
# (VibeTrunk/kut ADR-144). An empty plan file means the database is up to date.
#
# Usage: scripts/ci/plan-migrations.sh <kut-migrations-dir> <plan-file>
# Env:   DB_URL      connection URL without a password
#        PGPASSWORD  the password, read by the CLI from the environment
#        SUPABASE    CLI command (default: supabase)
set -euo pipefail

kut_dir=${1:?kut migrations directory}
plan_file=${2:?plan file}
read -r -a cli <<< "${SUPABASE:-supabase}"
: "${DB_URL:?}" "${PGPASSWORD:?}"

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

"${cli[@]}" migration list --agent no --db-url "$DB_URL"

if ! "${cli[@]}" db push --dry-run --agent no --db-url "$DB_URL" > "$work/dry.out" 2> "$work/dry.err"; then
  cat "$work/dry.out" "$work/dry.err" >&2
  echo "The dry run failed, so nothing is planned." >&2
  exit 1
fi
cat "$work/dry.err" "$work/dry.out"

: > "$plan_file"
# "Remote" against hosted, "Local" against a loopback test database.
if grep -qE '^(Remote|Local) database is up to date' "$work/dry.out" "$work/dry.err"; then
  echo "Plan: nothing pending."
  exit 0
fi
if ! grep -q '^Would push these migrations:' "$work/dry.err"; then
  echo "The dry run output has an unknown shape; refusing to plan." >&2
  exit 1
fi

refused=0
while IFS= read -r name; do
  if [[ ! "$name" =~ ^[0-9]{12,14}_[a-z0-9_]+\.sql$ ]]; then
    echo "REFUSED: unexpected migration name '$name'." >&2
    refused=1
  elif [[ ! -f "supabase/migrations/$name" ]]; then
    echo "REFUSED: $name is not in this catalogue commit." >&2
    refused=1
  elif [[ ! -f "$kut_dir/$name" ]] || ! cmp -s "supabase/migrations/$name" "$kut_dir/$name"; then
    echo "REFUSED: $name is not a KUT migration (no byte-identical copy in VibeTrunk/kut)." >&2
    refused=1
  else
    echo "$name $(sha256sum "supabase/migrations/$name" | cut -d' ' -f1)" >> "$plan_file"
  fi
done < <(sed -n 's/^ • //p' "$work/dry.err")

if [[ $refused -ne 0 ]]; then
  echo "Refusing the plan: every pending migration must be a KUT migration." >&2
  exit 1
fi
if [[ ! -s "$plan_file" ]]; then
  echo "The dry run listed no migrations; refusing to plan." >&2
  exit 1
fi
echo "Plan:"
cat "$plan_file"
