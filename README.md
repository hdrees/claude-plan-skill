# claude-plan-skill

A Claude Code plugin providing the **`plan`** skill: a structured planning and execution workflow
for software tasks. It manages task plans under `plans/<slug>/` in your project, each consisting of
a `task.md` (description + requirements) and a `plan.md` (phases → tasks as checkboxes), plus
per-task notes and findings.

## Installation

Add this repository as a plugin marketplace and install the `plan` plugin:

```
/plugin marketplace add hdrees/claude-plan-skill
/plugin install plan@claude-plan-skill
```

## Usage

Once installed, use the `/plan` command with a subcommand:

- `/plan new <description>` — create a new plan
- `/plan list` — list all plans
- `/plan status [slug]` — show progress
- `/plan next [slug]` — work on the next open task
- `/plan all [slug]` — work through all remaining tasks
- `/plan refine [slug] [phase]` — break down a phase
- `/plan note [slug] <text>` — save a finding
- `/plan delete [slug]` — remove a plan
- `/plan draft [slug]` / `/plan undraft [slug]` — gate execution

See `plugins/plan/skills/plan/SKILL.md` for full details.

## Requirements

The skill's helper scripts require `bash` and `jq`.

## Updating

Claude Code checks the marketplace for updates; use `/plugin marketplace update
claude-plan-skill` (or reinstall) to pick up new versions once published here.

## License

MIT — see [LICENSE](LICENSE).

<!-- CI test 2026-09-16T12:02:58Z -->
