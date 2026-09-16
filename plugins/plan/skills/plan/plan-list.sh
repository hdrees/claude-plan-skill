#!/usr/bin/env bash
# Lists all plans in plans/ with title and task progress.
# Output format (tab-separated): slug \t title \t done/total \t draft (1|0)
#
# The draft flag is read ONLY from the "> Created:" metadata line, never from
# anywhere else in the file, so a task description that happens to contain
# the literal text "| Draft" cannot be misread as the plan's own status.

set -euo pipefail

PLANS_DIR="${1:-plans}"

if [[ ! -d "$PLANS_DIR" ]]; then
  echo "NO_PLANS_DIR"
  exit 0
fi

for slug_dir in "$PLANS_DIR"/*/; do
  [[ -d "$slug_dir" ]] || continue
  slug=$(basename "$slug_dir")
  plan_file="$slug_dir/plan.md"
  task_file="$slug_dir/task.md"

  title=$(grep -m1 '^# ' "$task_file" 2>/dev/null | sed 's/^# //' | tr -d '\r\t' || echo "$slug")
  total=$({ grep -E '^\- \[' "$plan_file" 2>/dev/null || true; } | wc -l | tr -d ' ')
  done=$({ grep -E '^\- \[x\]' "$plan_file" 2>/dev/null || true; } | wc -l | tr -d ' ')
  metadata_line=$(grep -m1 '^> Created:' "$plan_file" 2>/dev/null || true)
  draft=0
  [[ "$metadata_line" == *"| Draft"* ]] && draft=1

  printf '%s\t%s\t%s/%s\t%s\n' "$slug" "$title" "$done" "$total" "$draft"
done
