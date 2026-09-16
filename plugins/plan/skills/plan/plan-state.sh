#!/usr/bin/env bash
# Outputs the full state of one plan in a single call.
# Usage: bash plan-state.sh <slug> [<plans-dir>]
# Output (tab-separated, one line):
#   task_index \t phase \t task \t done/total \t has_notes \t next_task \t next_task_index \t is_draft \t branch_mismatch \t recorded_branch
#
# task_index is the authoritative 1-based position of the current task among
# ALL checkbox lines in plan.md, in document order. It is resolved from
# .state.json when valid and not already checked off; otherwise it falls
# back to the first unchecked task. phase/task are derived from it purely
# for display — never used to relocate the task, since free-text matching
# breaks after /plan refine renames a task.

set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "JQ_MISSING: this script requires 'jq' to read .state.json. Install it (e.g. 'apt install jq' / 'brew install jq') and retry." >&2
  exit 1
fi

SLUG="${1:-}"
PLANS_DIR="${2:-plans}"

if [[ -z "$SLUG" ]]; then
  echo "MISSING_SLUG" >&2
  exit 1
fi

PLAN_DIR="$PLANS_DIR/$SLUG"
PLAN_FILE="$PLAN_DIR/plan.md"
STATE_FILE="$PLAN_DIR/.state.json"

if [[ ! -f "$PLAN_FILE" ]]; then
  echo "PLAN_NOT_FOUND"
  exit 1
fi

# One entry per checkbox line, in file order: "<status>\t<text>" (status is 'x' or ' ').
# Built with a read loop rather than mapfile/readarray for Bash 3.2 compatibility
# (macOS ships 3.2 as /bin/bash; mapfile requires Bash 4+).
checkbox_lines=()
while IFS= read -r line; do
  checkbox_lines+=("$line")
done < <(sed -nE 's/^\- \[(.)\] (.*)$/\1\t\2/p' "$PLAN_FILE")
total=${#checkbox_lines[@]}

status_at() { cut -f1 <<< "${checkbox_lines[$1]}"; }
text_at() { cut -f2- <<< "${checkbox_lines[$1]}"; }

done_count=0
if [[ "$total" -gt 0 ]]; then
  for idx in "${!checkbox_lines[@]}"; do
    [[ "$(status_at "$idx")" == "x" ]] && done_count=$((done_count + 1))
  done
fi

# Read the authoritative task_index from .state.json (1-based).
task_index=""
if [[ -f "$STATE_FILE" ]]; then
  task_index=$(jq -r '.task_index // empty' "$STATE_FILE")
fi

# Validate: must be a plain integer in range, and not already checked off.
if [[ -n "$task_index" ]] && { ! [[ "$task_index" =~ ^[0-9]+$ ]] || [[ "$task_index" -lt 1 ]] || [[ "$task_index" -gt "$total" ]] || [[ "$(status_at $((task_index - 1)))" == "x" ]]; }; then
  task_index=""
fi

# Fall back to the first unchecked task.
if [[ -z "$task_index" && "$total" -gt 0 ]]; then
  for idx in "${!checkbox_lines[@]}"; do
    if [[ "$(status_at "$idx")" != "x" ]]; then
      task_index=$((idx + 1))
      break
    fi
  done
fi

if [[ -z "$task_index" ]]; then
  phase=""
  task=""
  next_task="(none)"
  next_task_index=""
else
  task="$(text_at $((task_index - 1)))"
  line_no=$(grep -nE '^\- \[.\] ' "$PLAN_FILE" | sed -n "${task_index}p" | cut -d: -f1)
  phase=$(sed -n "1,${line_no}p" "$PLAN_FILE" | grep '^## ' | tail -1 | sed 's/^## //')

  next_task="(none)"
  next_task_index=""
  for ((idx = task_index; idx < total; idx++)); do
    if [[ "$(status_at "$idx")" != "x" ]]; then
      next_task="$(text_at "$idx")"
      next_task_index=$((idx + 1))
      break
    fi
  done
fi

[[ -z "$task_index" ]] && task_index=0

# Derive the notes file path from task_index — guaranteed collision-free,
# unlike a purely text-derived slug (two tasks can truncate to the same slug).
phase_slug=$(echo "$phase" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g; s/-\+/-/g; s/^-//; s/-$//' | cut -c1-40)
task_slug=$(echo "$task" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g; s/-\+/-/g; s/^-//; s/-$//' | cut -c1-40)
notes_file="$PLAN_DIR/tasks/${task_index}--${phase_slug}--${task_slug}.md"
has_notes=0
[[ -f "$notes_file" ]] && has_notes=1

# Draft flag and recorded branch are read ONLY from the "> Created:" metadata
# line, never from anywhere else in the file — a task description containing
# the literal text "| Draft" must not be misread as the plan's own status.
metadata_line=$(grep -m1 '^> Created:' "$PLAN_FILE" 2>/dev/null || true)

is_draft=0
[[ "$metadata_line" == *"| Draft"* ]] && is_draft=1

recorded_branch=$(grep -oE 'Branch: [^|]+' <<< "$metadata_line" | head -1 | sed 's/^Branch: //; s/[[:space:]]*$//' || true)
current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)

branch_mismatch=0
if [[ -n "$recorded_branch" && -n "$current_branch" && "$recorded_branch" != "$current_branch" ]]; then
  branch_mismatch=1
fi

printf '%s\t%s\t%s\t%s/%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$task_index" "$phase" "$task" "$done_count" "$total" "$has_notes" "$next_task" "$next_task_index" "$is_draft" "$branch_mismatch" "$recorded_branch"
