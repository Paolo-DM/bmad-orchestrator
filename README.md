# bmad-orchestrator

A shell-based orchestrator that automates [BMAD V6](https://github.com/bmadcode/BMAD-METHOD) development workflows using `claude -p` (Claude Code's headless print mode).

Replaces the "Claw Loop" (Clawdbot + tmux) with a simpler, more portable approach: one shell script + system cron. No persistent processes, no tmux sessions, no daemon to babysit.

## How it works

Each cron fire runs `bmad-loop.sh` once. It reads project state from a JSON file, determines what to do next, runs a single `claude -p` call, updates state, and exits. If another instance is already running (i.e., a previous `claude -p` hasn't finished), the lock file causes the new cron fire to exit immediately.

### Workflow per story

```
backlog
  │
  ▼
create-story ──► (claude creates story .md file)
  │
  ▼
dev-story ──────► (claude implements on feature branch, commits)
  │
  ▼
code-review ─────► (claude reviews, fixes, commits)
  │                 │
  │    [REVIEW_FIXED + passes remaining]
  │                 │
  │                 └──► code-review (next pass)
  │
  │    [REVIEW_CLEAN or max passes reached]
  │
  ▼
merge feat/story-N.M → base branch
  │
  ▼
close GitHub issue (optional)
  │
  ▼
advance to next story ──► repeat
```

### State machine

The orchestrator tracks a single `bmad-loop-state.json` file in the project's output directory:

| `status` value        | Meaning |
|-----------------------|---------|
| `running`             | Normal — cron fires execute work |
| `paused`              | Cron fires but all work is skipped |
| `human-review-needed` | Too many consecutive failures, or a HALT condition |
| `completed`           | All stories in the sprint are done |
| `stopped`             | Manually stopped via `stop` command |

---

## Prerequisites

| Tool | Install |
|------|---------|
| [Claude Code CLI](https://claude.ai/code) | `npm install -g @anthropic-ai/claude-code` |
| [yq](https://github.com/mikefarah/yq) v4+ | `brew install yq` |
| [jq](https://stedolan.github.io/jq/) | `brew install jq` |
| git | pre-installed on macOS |
| timeout (macOS) | `brew install coreutils` (provides `gtimeout`) |

> **yq version**: This tool requires yq v4 (the Go rewrite). `yq --version` should show `4.x`. yq v3 (Python) uses different syntax and is not compatible.

---

## Quick start

**1. Clone this repo:**
```bash
git clone https://github.com/your-username/bmad-orchestrator.git
cd bmad-orchestrator
```

**2. Copy the example config into your project:**
```bash
cp examples/bmad-loop.config.yaml /path/to/your/project/bmad-loop.config.yaml
```

**3. Edit the config** — at minimum, set `project.name` and `project.path`.

**4. Start the orchestrator:**
```bash
./bmad-loop-ctl.sh --config /path/to/your/project/bmad-loop.config.yaml start
```

This installs the cron job and immediately runs the first cycle. From here, the orchestrator runs autonomously every N minutes (default: 5).

**5. Monitor progress:**
```bash
./bmad-loop-ctl.sh --config /path/to/your/project/bmad-loop.config.yaml status
./bmad-loop-ctl.sh --config /path/to/your/project/bmad-loop.config.yaml logs
```

---

## Control commands

```
bmad-loop-ctl.sh --config <config.yaml> <command>

  start       Install cron job, initialize state, and run first cycle
  stop        Remove cron job and set state to stopped
  pause       Pause work (cron fires but skips — useful during manual debugging)
  resume      Resume after a pause
  status      Show current state in a formatted summary (with elapsed time)
  skip        Skip the current story and advance to the next one
  retry       Reset consecutive failures to 0 and set status to running
  logs        Tail the activity log (Ctrl-C to stop)
  watch       Tail the current step's live output (falls back to activity log if idle)
  progress    Show a formatted sprint progress view with story statuses
  run-once    Execute one cycle immediately (no cron required — good for testing)
  reset       Delete state file; next run will re-initialize from sprint-status.yaml
```

### Live output tailing

Each `claude -p` invocation is tee'd to a step-specific log file:

```
_bmad-output/implementation-artifacts/bmad-loop-steps/{story-num}/{step}-pass{N}-{timestamp}.log
```

This creates a full audit trail and lets you watch live progress:

```bash
# Watch the current step's output in real time
./bmad-loop-ctl.sh --config /path/to/config.yaml watch

# Or manually tail using the path shown in `status`
tail -f _bmad-output/implementation-artifacts/bmad-loop-steps/2.3/code-review-pass1-20240115T102345Z.log
```

### Sprint progress view

```bash
./bmad-loop-ctl.sh --config /path/to/config.yaml progress
```

```
=== BMAD Sprint Progress ===
Project: 3d-print-flow

Epic 2: [IN PROGRESS]
  ✓ 2.1 figure catalog view empty state
  ✓ 2.2 create edit figure with color assignment
  ► 2.3 delete figure with cascade confirmation [code-review pass 1]
  · 2.4 catalog to queue live binding

Epic 3: [BACKLOG]
  · 3.1 ...

Progress: 2/6 stories (33%) | Current: 2.3 | Failures: 0
```

### Retry after stall

When the loop hits `human-review-needed`, fix the underlying issue and retry without fully resetting:

```bash
./bmad-loop-ctl.sh --config /path/to/config.yaml retry
```

This resets `consecutiveFailures` to 0 and sets status back to `running`.

### Dry run

You can test what `bmad-loop.sh` would do without actually running `claude -p` or modifying any state:

```bash
./bmad-loop.sh --dry-run /path/to/bmad-loop.config.yaml
```

In dry-run mode the full prompt, model, budget, and feature branch are printed.

---

## Config file reference

```yaml
project:
  name: "my-project"                    # Display name used in logs
  path: "/abs/path/to/project"          # Absolute path to the project repo
  sprint_status: "path/to/sprint-status.yaml"   # Relative to project.path
  story_location: "path/to/stories"             # Where story .md files live

branch_strategy:
  base_branch: "develop"                # Feature branches are cut from here
  feature_branch_prefix: "feat/"        # e.g., feat/story-2.1
  merge_after_review: true              # Auto-merge into base after review passes
  push_after_merge: true                # Auto-push base branch after merge

models:
  create_story: "opus"                  # Model for /bmad-create-story
  code_review: "opus"                   # Model for /bmad-code-review (adversarial)
  dev_story_default: "sonnet"           # Default model for /bmad-dev-story
  epic_overrides:                       # Override per epic (optional)
    epic-2: "sonnet"
    epic-3: "opus"
  story_overrides:                      # Override per story — highest precedence (optional)
    2-4-some-story-slug: "opus"

budget:
  create_story_max_usd: 2
  dev_story_max_usd: 5
  code_review_max_usd: 3

timeouts:
  create_story_seconds: 300
  dev_story_seconds: 1800
  code_review_seconds: 900

workflow:
  max_review_passes: 3                  # Review cycles before advancing regardless
  max_consecutive_failures: 3           # Pause for human after this many failures in a row
  update_github_issues: true            # Close GitHub issue when story completes
  extra_dev_instructions: |             # Appended to every dev-story prompt (optional)
    Custom instructions here.
  extra_review_instructions: |          # Appended to every code-review prompt (optional)
    Custom review instructions here.

notifications:
  log_file: "path/to/activity.log"      # Relative to project.path
  desktop: true                          # macOS desktop notifications (default: true on macOS)

cron:
  interval_minutes: 5
```

---

## Activity log format

Each line in the activity log is:

```
2025-01-15T10:23:45Z | EVENT | key:value | key:value ...
```

Common event types:

| Event | Meaning |
|-------|---------|
| `INIT` | State file created, first story queued |
| `CRON_FIRE` | A cycle started for a given step |
| `CRON_SKIP` | Cycle skipped (paused / human-review-needed / completed) |
| `TRANSITION` | Moved from one step to the next |
| `REVIEW_DONE` | Code review cycle finished |
| `REVIEW_RERUN` | Review found issues; queued another pass |
| `REVIEW_MAX` | Max review passes reached; advancing anyway |
| `STORY_DONE` | Story fully completed |
| `MERGE` | Feature branch merged into base |
| `ADVANCE` | Moved to the next story in the queue |
| `EPIC_DONE` | All stories in an epic completed |
| `SPRINT_DONE` | All stories in the sprint completed |
| `FAILURE` | A `claude -p` call failed or produced unexpected output |
| `STALL` | Consecutive failure threshold reached; paused for human |
| `HALT` | Agent emitted `BMAD_RESULT:HALT:reason` |
| `SKIP` | Step skipped (e.g., story already past backlog) |
| `MANUAL_SKIP` | Story manually skipped via `skip` command |

---

## Sprint status format

The orchestrator reads `sprint_status.yaml` to determine story order and updates it as work progresses. Expected format:

```yaml
development_status:
  2-1-figure-catalog-view-empty-state: backlog
  2-2-some-other-story: backlog
  2-3-yet-another-story: backlog
  epic-2: in-progress
```

Story keys must match the pattern `^[0-9]+-[0-9]+` (epic-story prefix). Lines matching `epic-N` are treated as epic markers and are updated when all stories in an epic are done.

Status flow: `backlog` → `ready-for-dev` → `review` → `done`

---

## Multi-project usage

You can run multiple projects simultaneously. Each project has its own config file, its own state file, and its own cron entry. The lock file is keyed by a hash of the config file path, so they never interfere:

```bash
bmad-loop-ctl.sh --config ~/projects/app-a/bmad-loop.config.yaml start
bmad-loop-ctl.sh --config ~/projects/app-b/bmad-loop.config.yaml start
```

---

## Monitoring with Dispatch

A convenient way to watch multiple projects is to watch the activity logs:

```bash
# Single project
bmad-loop-ctl.sh --config /path/to/config.yaml logs

# Multiple projects with multitail (brew install multitail)
multitail \
  /path/to/app-a/_bmad-output/implementation-artifacts/bmad-loop-activity.log \
  /path/to/app-b/_bmad-output/implementation-artifacts/bmad-loop-activity.log
```

---

## Troubleshooting

**Loop says "Another instance is already running"**
A previous `claude -p` call is still running (likely still implementing/reviewing). This is normal — the lock is released automatically when the process finishes. If you suspect the process died and left a stale lock:
```bash
rm -rf /tmp/bmad-loop-*.lock
```

**Loop stalled with `human-review-needed`**
Check the activity log for the preceding `FAILURE` entries (or review the step output log shown in `status`). Fix whatever the agent was struggling with, then:
```bash
# Retry the same story (resets failure count)
bmad-loop-ctl.sh --config /path/to/config.yaml retry

# Or resume (keeps failure count — safe after a pause)
bmad-loop-ctl.sh --config /path/to/config.yaml resume

# Or skip the problematic story entirely
bmad-loop-ctl.sh --config /path/to/config.yaml skip
```

**Story file not found after create-story**
The story file is searched in `story_location` by filename `<story-key>.md`. Verify the BMAD create-story workflow is creating files there, and that `story_location` in the config points to the correct directory.

**`yq` command errors**
Make sure you have yq v4 (`brew install yq`), not the Python yq v3. They use different syntax. Check with `yq --version`.

**`timeout: command not found` on macOS**
Install coreutils: `brew install coreutils`. The orchestrator will use `gtimeout` if available, falling back to `timeout`, and will warn but continue without a timeout if neither is found.

**Cron job installed but nothing runs**
- Check the cron log: `cat /tmp/bmad-cron-<hash>.log`
- Ensure the `bmad-loop.sh` path is absolute in the crontab
- On macOS, cron may need Full Disk Access in System Preferences → Privacy & Security
- Verify `claude` is on PATH in cron context: add `export PATH="/usr/local/bin:$PATH"` or similar to your crontab

---

## Architecture

```
bmad-orchestrator/
├── bmad-loop.sh           Main orchestrator — runs one action per invocation
├── bmad-loop-ctl.sh       Control script — start/stop/pause/status/etc.
├── prompts/
│   ├── create-story.md    Reference template for the create-story prompt
│   ├── dev-story.md       Reference template for the dev-story prompt
│   └── code-review.md     Reference template for the code-review prompt
├── examples/
│   └── bmad-loop.config.yaml   Annotated example configuration
└── README.md
```

State is stored in `<project.path>/_bmad-output/implementation-artifacts/`:
- `bmad-loop-state.json` — current orchestrator state (step, story, failures, elapsed time, etc.)
- `bmad-loop-activity.log` — append-only activity log
- `bmad-loop-steps/{story-num}/{step}-pass{N}-{timestamp}.log` — per-step output logs for live tailing and audit
