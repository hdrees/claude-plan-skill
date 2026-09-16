---
name: plan
description: Structured planning and execution workflow for software tasks. Use this skill whenever the user invokes /plan with any subcommand: "new" to create a plan, "next" to work on the next open task, "all" to work through all remaining tasks, "status" to see progress, "list" to see all plans, "refine" to break down a phase, "note" to save a finding, "delete" to remove one specific plan, or "draft"/"undraft" to gate execution. Several subcommands take a plan slug as their first parameter to target a specific plan. Always use this skill when /plan is typed — even if the request seems simple, the skill manages file state that Claude cannot otherwise track.
argument-hint: "new <description> | list | status [slug] | next [slug] | all [slug] | refine [slug] [phase] | note [slug] <text> | delete [slug] | draft [slug] | undraft [slug]"
---

# Plan Skill

Manages structured task plans under `plans/<slug>/` in the **current working directory**.
Each plan consists of two files: `task.md` (task description + requirements) and `plan.md` (phases → tasks with Markdown checkboxes).
Questions and findings are stored per task as individual Markdown files.

## File Structure

```
plans/
  .active                             # Contains the slug of the currently active plan
  <slug>/
    task.md                           # Task description and requirements
    plan.md                           # Execution plan: phases → tasks (checkboxes)
    .state.json                       # Tracks the currently active task within this plan
    tasks/
      <task-index>--<phase-slug>--<task-slug>.md  # Notes, questions, results per task
```

The `<task-index>` prefix (the task's 1-based position among all checkboxes in
`plan.md`) makes the filename collision-free even when two tasks' descriptions
truncate to the same slug — plain text slugging alone cannot guarantee that.

---

## Shared Rules

The following rules are referenced by name throughout this document to avoid repetition.

### RULE: Script Path Resolution

This skill's helper scripts (`plan-state.sh`, `plan-list.sh`, `plan-phase-check.sh`) live next to this `SKILL.md` file — but that file can be installed either project-locally (`.claude/skills/plan/`, relative to the current working directory) or globally (`~/.claude/skills/plan/`). Resolve this once at the start of a session and reuse the result:

1. If `.claude/skills/plan/plan-state.sh` exists relative to the current working directory, set `PLAN_SKILL_DIR` to that path.
2. Otherwise, set `PLAN_SKILL_DIR` to `$HOME/.claude/skills/plan`.

Every command below invokes scripts as `bash "$PLAN_SKILL_DIR/<script>.sh" ...` — resolve `$PLAN_SKILL_DIR` once, don't hardcode the global path, and don't re-resolve it per command within the same session.

### RULE: Plan Selection

Used by `/plan refine`, `/plan next`, `/plan all`, `/plan status`, `/plan note`, `/plan draft`, `/plan undraft`, `/plan delete` — all of which take an optional `<slug>` as their first parameter.

1. → Apply **Script Path Resolution**.
2. **If `<slug>` is given:** verify `plans/<slug>/plan.md` exists (if not, inform the user and stop). Write `plans/.active` with `<slug>` (overwrite any previous value) — this becomes the new "last used" plan for future parameter-less invocations.
3. **If `<slug>` is omitted:**
   - Read `plans/.active` for the last used slug.
   - If `.active` is missing or empty: run `/plan list` and ask the user which plan to use. Do not guess.
   - Otherwise, **ask the user to confirm** before proceeding, e.g.:
     > No plan specified — the last used plan was `<slug>`. Continue with this one? (Yes / No / a different slug)
     Wait for explicit confirmation before executing the command. If the user names a different slug instead, use that one (and write it to `plans/.active` per step 2).
4. Proceed with the resolved slug.

### RULE: Draft Mode Rejection

Check `plans/<slug>/plan.md` for `| Draft` in the metadata line. If found, refuse (replace `[ACTION]` with the relevant verb for the current command, e.g. `executed`, `refined`):
> This plan is a draft and cannot be [ACTION] yet. Remove the draft status first with `/plan undraft <slug>`.

### RULE: Branch Mismatch Warning

`plan-state.sh`'s `branch_mismatch`/`recorded_branch` fields compare the git branch the plan was created on against the branch currently checked out (empty `recorded_branch` means the plan predates this check, or the directory isn't a git repo — skip silently in that case). If `branch_mismatch == 1`, surface a warning before doing any work, but do not block — the user may have a legitimate reason to keep working:
> ⚠️ This plan was created on branch `<recorded_branch>`; the current branch is different. Tasks may reference code that doesn't exist here. Continue?
Wait for confirmation before proceeding.

### RULE: Atomic State Write

Never overwrite `plans/<slug>/.state.json` by editing it in place. A write interrupted mid-way (e.g. session cut off) leaves a half-written, unreadable file, silently discarding the plan's position. Instead, write the new content to a temp file in the same directory and rename it into place:

```bash
cat > "plans/<slug>/.state.json.tmp" <<'EOF'
{ "task_index": <N>, "phase": "<phase>", "task": "<task>" }
EOF
mv "plans/<slug>/.state.json.tmp" "plans/<slug>/.state.json"
```

`mv` within the same directory is atomic, so a reader never observes a partial file. Apply this pattern every time `.state.json` is created or updated (`/plan new`, `/plan next`, `/plan all`, `/plan refine`).

### PATTERN: Metadata Flag Edit

Used by `draft`, `undraft`. Parameters: `flag` (`Draft`), `action` (`append` or `remove`).

1. → Apply **Plan Selection** to resolve `<slug>`.
2. Edit the `> Created:` metadata line in `plan.md`:
   - **append**: add ` | <flag>` at the end (only if not already present)
   - **remove**: delete ` | <flag>`
3. Confirm the result to the user.

---

## Commands

### `/plan new <description>`

Create a new plan from a free-form task description.

**Confirmation guard:** Only proceed immediately if the user explicitly typed `/plan new` (the literal subcommand `new` was present in the invocation). If the skill was triggered without an explicit `new` — for example by typing just `/plan`, or because the harness auto-invoked it — stop and ask:
> Should a new plan really be created? (Yes / No)
Do not create any files until the user confirms.

1. Derive **5 distinct short kebab-case slug candidates** (max 5 words each) from the description — vary the angle (different key nouns, verb-first vs. noun-first phrasing, different scope granularity) so the options are meaningfully different, not just synonyms of the same phrase. Present them as a numbered list and ask the user to pick one, or supply their own slug instead:
   > Suggested plan names:
   > 1. `<slug-a>`
   > 2. `<slug-b>`
   > 3. `<slug-c>`
   > 4. `<slug-d>`
   > 5. `<slug-e>`
   >
   > Pick a number, or provide your own.
   Wait for the user's choice before proceeding.
   **Check for conflicts** on the chosen slug: if `plans/<slug>/` already exists, inform the user and ask whether to use the existing plan instead (by passing its slug to another command, e.g. `/plan status <slug>`) or choose a different slug (from the remaining suggestions, or a new one). Do not overwrite silently.
2. Create `plans/<slug>/` and `plans/<slug>/tasks/`.
3. **Before writing the plan, explore the codebase** to understand existing patterns: look at analogous modules, data models, API shapes, file structures, and naming conventions. The plan should be grounded in what actually exists.
4. Analyze the task thoroughly: break it into **2–5 logical phases**, each with **2–5 concrete, actionable tasks**. For each phase, estimate the effort using one of three levels: **Low**, **Medium**, **High**.
5. **Tasks must be specific and self-contained** — include all technical detail needed to execute without further lookup:
   - Database tasks: list all columns with types, constraints, and indexes
   - API tasks: list request params, response fields, HTTP method and route
   - Type/interface tasks: list all fields with their TypeScript types
   - Component tasks: list props, emits, and slots
   - File tasks: list exact paths to create or modify

   Use sub-bullets (`  -`) under a task for this detail. The goal is that someone can pick up any task cold and know exactly what to build.
6. Write `plans/<slug>/task.md` using this template:

```markdown
# <Title>

> Created: <YYYY-MM-DD>

## Task

<Original task description verbatim>

## Requirements

<Bullet list of concrete, derived requirements extracted from the task analysis — what the solution must satisfy>
```

7. Determine the current git branch (`git rev-parse --abbrev-ref HEAD 2>/dev/null`); if the command fails (not a git repo), omit the `Branch:` segment entirely. Write `plans/<slug>/plan.md` using this template:

```markdown
# Plan: <Title>

> Created: <YYYY-MM-DD> | Branch: <branch-name> | Status: In Progress

## Phase 1: <Phase Name> (Effort: <Low|Medium|High>)

- [ ] <Task description>
  - <specific detail, e.g. column: `name varchar(255) not null`>
  - <specific detail, e.g. route: `GET /api/vehicles/v1?lang=&page=&search=`>
- [ ] <Task description>

## Phase 2: <Phase Name> (Effort: <Low|Medium|High>)

- [ ] <Task description>
- [ ] <Task description>

---
**Total effort: <Low|Medium|High>**
```

8. → Apply **Atomic State Write** to write `plans/<slug>/.state.json` pointing to the first task. `task_index` is the authoritative field — the 1-based position of the task among ALL checkbox lines in `plan.md`, top to bottom regardless of phase (the first checkbox in the file is `1`). `phase`/`task` are informational copies for human readability only and are never used for lookup:

```json
{
  "task_index": 1,
  "phase": "Phase 1: <Phase Name>",
  "task": "<First task description>"
}
```

9. Write `plans/.active` with the slug of the new plan (a single line, no trailing newline):

```
<slug>
```

10. Show both `task.md` and `plan.md` and ask whether they look good or need adjustments before proceeding.

---

### `/plan list`

List all plans found under `plans/` in the current directory.

→ Apply **Script Path Resolution**. Run this single command to gather the data (no further shell calls needed):

```bash
bash "$PLAN_SKILL_DIR/plan-list.sh"
```

If the output is `NO_PLANS_DIR`, tell the user there are no plans yet.
Otherwise parse the tab-separated lines (`slug \t title \t done/total \t draft`) and render them as a Markdown table:

| | Slug | Title | Progress | Completed | Draft |
|---|---|---|---|---|---|

- **Column 1 (Active)**: `▶` if the slug matches the content of `plans/.active`, otherwise empty
- **Progress**: the `done/total` value
- **Completed**: ✅ if `done == total` (and total > 0), otherwise empty
- **Draft**: 📝 if `draft == 1`, otherwise empty

---

### `/plan delete [slug]`

Delete one specific plan.

1. → Apply **Plan Selection** to resolve `<slug>`.
2. Run: `bash "$PLAN_SKILL_DIR/plan-list.sh"` and find the matching row to show the plan's title and progress (`done/total`).
3. If the plan is not fully completed (`done < total`), warn the user that it still has open tasks.
4. **Ask for explicit confirmation** before deleting, showing slug + title + progress.
5. After confirmation, delete the plan directory: `rm -rf plans/<slug>`. If `plans/.active` contained this slug, remove it.
6. Confirm the plan was deleted.

---

### `/plan status`

Show the currently active plan and highlight the active task.

1. → Apply **Plan Selection** to resolve `<slug>`. If no plan can be resolved, run `/plan list` instead.
2. Run: `bash "$PLAN_SKILL_DIR/plan-state.sh" <slug>`
   Parse output: `task_index \t phase \t task \t done/total \t has_notes \t next_task \t next_task_index \t is_draft \t branch_mismatch \t recorded_branch`
   If the script exits with `JQ_MISSING`, tell the user `jq` must be installed for the plan skill to work and stop.
   If `branch_mismatch == 1`: → Apply **Branch Mismatch Warning**.
3. Display `plans/<slug>/task.md` (task description + requirements).
4. Display `plans/<slug>/plan.md` (all phases + tasks), with the active task marked:
   - Prefix the active task line with `▶` and bold the task text:
     `▶ **- [ ] Write API endpoint**`
5. Show a one-line summary below the plan:
   > **Active:** Phase X · `<task description>` — `Y/Z tasks done`

---

### `/plan next`

Work on the next open task — this is the core execution command.

1. → Apply **Plan Selection** to resolve `<slug>`.
   Run: `bash "$PLAN_SKILL_DIR/plan-state.sh" <slug>`
   Parse output: `task_index \t phase \t task \t done/total \t has_notes \t next_task \t next_task_index \t is_draft \t branch_mismatch \t recorded_branch`
   If the script exits with `JQ_MISSING`, tell the user `jq` must be installed for the plan skill to work and stop.
   If `is_draft == 1`: → Apply **Draft Mode Rejection** (`[ACTION]` = `executed`).
   If `branch_mismatch == 1`: → Apply **Branch Mismatch Warning**.
   The script already resolves `task_index`/`phase`/`task` to the correct current task (falling back to the first unchecked task when `.state.json` is missing, stale, or points at an already-checked task) — use them as-is; there is no separate "missing state" case to handle.
2. If `has_notes == 1`, load `plans/<slug>/tasks/<task_index>--<phase-slug>--<task-slug>.md` (prior notes, open questions, context from previous sessions).
3. Announce clearly at the start:
   > **Phase X · Task:** `<task description>`
4. **Actively help accomplish the task**: write code, create files, run commands, explain decisions — whatever the task requires.
5. After completing the work:
   - Check off the task in `plan.md`: change `- [ ]` to `- [x]`
   - Save findings/results to `plans/<slug>/tasks/<task_index>--<phase-slug>--<task-slug>.md` (see format below)
   - Re-run `plan-state.sh` to get the freshly resolved `task_index`/`phase`/`task` for the next unchecked task, then → Apply **Atomic State Write** to persist it into `.state.json`.
   - Show what comes next

**How to derive the notes file name:**
`<task_index>--<phase-slug>--<task-slug>.md`, where `task_index` is the number `plan-state.sh` reported, and `phase-slug`/`task-slug` are the phase heading and task text lowercased, with spaces/special characters replaced by `-`, trimmed to max 40 chars each.
Example: `task_index=5`, `Phase 2: Implementation`, `Write API endpoint` → `5--phase-2-implementation--write-api-endpoint.md`. The numeric prefix alone already guarantees uniqueness — no collision handling needed.

---

### `/plan all`

Work through **all remaining open tasks** in the active plan, phase by phase, without stopping between tasks.

1. → Apply **Plan Selection** to resolve `<slug>`.
   Run: `bash "$PLAN_SKILL_DIR/plan-state.sh" <slug>`
   Parse output: `task_index \t phase \t task \t done/total \t has_notes \t next_task \t next_task_index \t is_draft \t branch_mismatch \t recorded_branch`
   If the script exits with `JQ_MISSING`, tell the user `jq` must be installed for the plan skill to work and stop.
   If `is_draft == 1`: → Apply **Draft Mode Rejection** (`[ACTION]` = `executed`).
   If `branch_mismatch == 1`: → Apply **Branch Mismatch Warning**.
   The script already resolves `task_index` to the correct current task — start there.
2. For each unchecked task (in order):
   - Announce: **Phase X · Task:** `<task description>`
   - If `has_notes == 1`, load `plans/<slug>/tasks/<task_index>--<phase-slug>--<task-slug>.md`
   - Actively accomplish the task (write code, create files, run commands)
   - Check off the task in `plan.md`: `- [ ]` → `- [x]`
   - Save findings to `plans/<slug>/tasks/<task_index>--<phase-slug>--<task-slug>.md`
   - Re-run `plan-state.sh` to get the freshly resolved `task_index`/`phase`/`task` for the next task, then → Apply **Atomic State Write** to persist it into `.state.json`
3. Continue until all tasks are `[x]` or a blocker is hit that requires user input.
4. When done, report: all tasks completed, or which task blocked and why.

---

### `/plan refine [phase-number]`

Break a phase down into more granular tasks, or enrich existing tasks with more technical detail.

1. → Apply **Plan Selection** to resolve `<slug>`.
2. → Apply **Draft Mode Rejection** (`[ACTION]` = `refined`).
3. If a phase number is given, refine that phase. Otherwise ask which phase, or default to the phase containing the current task.
4. Read the existing tasks of that phase from `plan.md`.
5. **Check if the phase is locked**: run `bash "$PLAN_SKILL_DIR/plan-phase-check.sh" <slug> <phase-number>` and parse `status \t done \t total`. This is a script-verified check — do not eyeball `plan.md` for this instead, since a missed unchecked task is easy to overlook by reading alone. If `status == LOCKED`, refuse:
   > Phase X is fully completed and locked. Completed phases cannot be modified. Use `/plan new` to start a new plan.
6. Explore the codebase as needed to ground the refinement in actual patterns.
7. Propose a more detailed breakdown: more tasks where scope is too broad, and sub-bullet details (schemas, API fields, file paths, types) where tasks lack specifics.
8. Preserve tasks already marked `[x]` — only expand unchecked ones within the phase.
9. Update the effort estimate (`Low`/`Medium`/`High`) in the phase heading and the **Total effort** line at the bottom, if the refinement changes the scope.
10. Update `plan.md` with the refined task list.
11. Splitting or reordering tasks shifts every later checkbox's position in the file, which invalidates existing `<task_index>--...` notes filenames for every task after the split point. For each notes file under `plans/<slug>/tasks/` whose task still exists after the refinement, rename it so its numeric prefix matches the task's new position (re-run `plan-state.sh` for the task in question, or recount checkboxes directly, to get the new index).
12. After updating `plan.md` (and renaming notes files), re-run `bash "$PLAN_SKILL_DIR/plan-state.sh" <slug>` and → Apply **Atomic State Write** to overwrite `.state.json` with the freshly resolved `task_index`/`phase`/`task` — never leave the old `task_index` in place, since it now points at a different task.

---

### `/plan note <text>`

Add a note, question, or finding to the current task's notes file.

1. → Apply **Plan Selection** to resolve `<slug>`.
   Run: `bash "$PLAN_SKILL_DIR/plan-state.sh" <slug>`
   Parse output: `task_index \t phase \t task \t done/total \t has_notes \t next_task \t next_task_index \t is_draft \t branch_mismatch \t recorded_branch` — use `task_index`, `phase` and `task`.
   If the script exits with `JQ_MISSING`, tell the user `jq` must be installed for the plan skill to work and stop.
2. Derive the task file path: `plans/<slug>/tasks/<task_index>--<phase-slug>--<task-slug>.md`.
3. Append to the file (create it if it doesn't exist) under the appropriate section:
   - For questions or open points: `## Open Questions` (as `- [ ] <text>`)
   - For findings or decisions: `## Notes` (as a bullet)
4. Confirm where it was saved.

---

### `/plan draft [slug]`

Mark a plan as a draft so it cannot be executed with `/plan next`.
→ Apply **Metadata Flag Edit** with `flag = Draft`, `action = append`.
Confirm: "Plan `<slug>` is now marked as a draft. `/plan next` is locked until the status is removed with `/plan undraft <slug>`."

---

### `/plan undraft [slug]`

Remove the draft status from a plan, allowing it to be executed again.
→ Apply **Metadata Flag Edit** with `flag = Draft`, `action = remove`.
Confirm: "Plan `<slug>` is no longer a draft and can be executed with `/plan next`."

---

## Task Notes File Format

`tasks/<task-index>--<phase-slug>--<task-slug>.md`:

```markdown
# <Task Title>

## Notes

- <decisions, context, links to created files>

## Open Questions

- [ ] <open question or point>
- [x] <answered question — add the answer below>

## Results

<Summary of what was accomplished in this task>
```

---

## Git Recommendation

Plans contain internal task descriptions, decisions and open questions — not production code. Add `plans/` to `.gitignore`, unless the project explicitly requires collaborative planning in the repository:

```
# .gitignore
plans/
```

If `plans/` should be committed after all (e.g. for team transparency), `.active` should be excluded, since it reflects local state:

```
# .gitignore
plans/.active
```

---

## Guidelines for Good Plans

- **Phases** should represent logical milestones or areas of concern — not arbitrary time slots.
- **Tasks** should be concrete enough to accomplish in one working session.
- Start with coarser phases and refine with `/plan refine` as the picture becomes clearer.
- Use `/plan note` to capture decisions and open questions *while working*, so context survives across sessions.
- The task notes files are the memory of the plan — write them as if briefing a colleague who picks up where you left off.
- **Completed phases are immutable.** Once every task in a phase is `[x]`, `/plan refine` refuses to modify it — enforced by `plan-phase-check.sh`, not left to eyeballing the text. This preserves the integrity of finished work.
