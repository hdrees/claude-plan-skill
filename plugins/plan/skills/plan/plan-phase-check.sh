#!/usr/bin/env bash
# Reports whether a given phase is fully completed (every checkbox under it
# is '[x]', none left '[ ]' open). Used to gate /plan refine with a
# script-verified answer instead of the model eyeballing the text.
#
# Usage: bash plan-phase-check.sh <slug> <phase-number> [<plans-dir>]
# Output (tab-separated, one line): status \t done \t total
#   status is LOCKED (fully done, total > 0) or OPEN.

set -euo pipefail

SLUG="${1:-}"
PHASE_NUM="${2:-}"
PLANS_DIR="${3:-plans}"

if [[ -z "$SLUG" || -z "$PHASE_NUM" ]]; then
  echo "MISSING_ARGS" >&2
  exit 1
fi

PLAN_FILE="$PLANS_DIR/$SLUG/plan.md"

if [[ ! -f "$PLAN_FILE" ]]; then
  echo "PLAN_NOT_FOUND"
  exit 1
fi

awk -v target="$PHASE_NUM" '
  /^## / { phase_count++; in_target = (phase_count == target) }
  in_target && /^\- \[.\] / {
    total++
    if ($0 ~ /^\- \[x\] /) done++
  }
  END {
    total = total + 0; done = done + 0
    status = (total > 0 && done == total) ? "LOCKED" : "OPEN"
    printf "%s\t%s\t%s\n", status, done, total
  }
' "$PLAN_FILE"
