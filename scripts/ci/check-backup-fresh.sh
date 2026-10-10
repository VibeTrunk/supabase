#!/usr/bin/env bash
# Passes when VibeTrunk/kut's encrypted backup (backup.yml, ADR-141) finished
# successfully on main within the last MAX_AGE_MINUTES (default 60). Reads
# public run metadata only.
#
# Usage: GH_TOKEN=... scripts/ci/check-backup-fresh.sh
set -euo pipefail

max_age=${MAX_AGE_MINUTES:-60}
run=$(gh api "repos/VibeTrunk/kut/actions/workflows/backup.yml/runs?branch=main&status=success&per_page=10" \
  --jq '[.workflow_runs[] | select(.event != "pull_request")][0] // empty | "\(.updated_at) \(.html_url)"')

if [[ -z "$run" ]]; then
  echo "No successful kut backup on main. Start one with: gh workflow run backup.yml -R VibeTrunk/kut" >&2
  exit 1
fi

finished=${run%% *}
age=$(( ($(date -u +%s) - $(date -u -d "$finished" +%s)) / 60 ))
if (( age > max_age )); then
  echo "The last kut backup finished $age minutes ago (${run#* }), over $max_age." >&2
  echo "Start a fresh one with: gh workflow run backup.yml -R VibeTrunk/kut, then rerun this job." >&2
  exit 1
fi
echo "Fresh kut backup: finished $age minutes ago, ${run#* }"
