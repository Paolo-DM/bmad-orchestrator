#!/usr/bin/env bash
set -euo pipefail

# bmad-loop-ctl.sh — Control script for the BMAD Loop orchestrator

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOOP_SCRIPT="$SCRIPT_DIR/bmad-loop.sh"

# ─── PLATFORM HELPERS ──────────────────────────────────────────────────────────
IS_MACOS=false
[[ "$(uname)" == "Darwin" ]] && IS_MACOS=true

config_hash() {
  if $IS_MACOS; then
    printf '%s' "$1" | md5
  else
    printf '%s' "$1" | md5sum | cut -d' ' -f1
  fi
}

# ─── USAGE ─────────────────────────────────────────────────────────────────────
usage() {
  cat << EOF
BMAD Loop Orchestrator Control

Usage: bmad-loop-ctl.sh --config <config.yaml> <command>

Commands:
  start       Install cron job, initialize state, and run first cycle
  stop        Remove cron job and set state to stopped
  pause       Set state to paused (cron fires but skips all work)
  resume      Set state back to running
  status      Show current state and progress
  skip        Skip current story and advance to the next one
  logs        Tail the activity log (Ctrl-C to exit)
  run-once    Execute one cycle immediately (useful for testing)
  reset       Remove state file so next run reinitializes from sprint-status.yaml

Examples:
  bmad-loop-ctl.sh --config ~/projects/myapp/bmad-loop.config.yaml start
  bmad-loop-ctl.sh --config ~/projects/myapp/bmad-loop.config.yaml status
  bmad-loop-ctl.sh --config ~/projects/myapp/bmad-loop.config.yaml logs
EOF
}

# ─── ARGUMENT PARSING ──────────────────────────────────────────────────────────
CONFIG_FILE=""
COMMAND=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config|-c) CONFIG_FILE="$2"; shift 2 ;;
    -*) echo "Unknown flag: $1" >&2; usage; exit 1 ;;
    *) COMMAND="$1"; shift ;;
  esac
done

if [[ -z "$CONFIG_FILE" || -z "$COMMAND" ]]; then
  usage; exit 1
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Config file not found: $CONFIG_FILE" >&2; exit 1
fi

CONFIG_FILE="$(cd "$(dirname "$CONFIG_FILE")" && pwd)/$(basename "$CONFIG_FILE")"

# ─── DEPENDENCY CHECK ──────────────────────────────────────────────────────────
for dep in jq yq; do
  if ! command -v "$dep" >/dev/null 2>&1; then
    echo "ERROR: Required dependency '$dep' not found." >&2
    [[ "$dep" == "yq" ]] && echo "  Install: brew install yq" >&2
    [[ "$dep" == "jq" ]] && echo "  Install: brew install jq" >&2
    exit 1
  fi
done

# ─── DERIVED PATHS ─────────────────────────────────────────────────────────────
PROJECT_DIR=$(yq '.project.path' "$CONFIG_FILE")
STATE_FILE="${PROJECT_DIR}/_bmad-output/implementation-artifacts/bmad-loop-state.json"
LOG_FILE_REL=$(yq '.notifications.log_file' "$CONFIG_FILE")
LOG_FILE="${PROJECT_DIR}/${LOG_FILE_REL}"
CRON_INTERVAL=$(yq '.cron.interval_minutes' "$CONFIG_FILE")
PROJECT_NAME=$(yq '.project.name' "$CONFIG_FILE")

# Unique cron identifier based on config path hash
CRON_HASH=$(config_hash "$CONFIG_FILE" | head -c 8)

# ─── COMMAND DISPATCH ──────────────────────────────────────────────────────────
case "$COMMAND" in

  # ── START ────────────────────────────────────────────────────────────────────
  start)
    # Ensure output directories exist
    mkdir -p "$(dirname "$STATE_FILE")"
    mkdir -p "$(dirname "$LOG_FILE")"

    # Install cron job (idempotent — remove existing entry for this config first)
    CRON_MARKER="# bmad-loop:$CRON_HASH"
    CRON_LINE="*/${CRON_INTERVAL} * * * * $LOOP_SCRIPT $CONFIG_FILE >> /tmp/bmad-cron-${CRON_HASH}.log 2>&1 $CRON_MARKER"

    existing=$(crontab -l 2>/dev/null || true)
    filtered=$(echo "$existing" | grep -v "bmad-loop:$CRON_HASH" || true)
    printf '%s\n%s\n' "$filtered" "$CRON_LINE" | grep -v '^$' | crontab -

    echo "Cron installed: every $CRON_INTERVAL minute(s) for project '$PROJECT_NAME'"
    echo "Cron log: /tmp/bmad-cron-${CRON_HASH}.log"

    # Run first cycle immediately
    echo ""
    echo "Running first cycle..."
    bash "$LOOP_SCRIPT" "$CONFIG_FILE"

    echo ""
    echo "BMAD Loop started."
    echo "Monitor: $0 --config $CONFIG_FILE status"
    echo "Logs:    $0 --config $CONFIG_FILE logs"
    ;;

  # ── STOP ─────────────────────────────────────────────────────────────────────
  stop)
    # Remove cron entry
    existing=$(crontab -l 2>/dev/null || true)
    if echo "$existing" | grep -q "bmad-loop:$CRON_HASH"; then
      echo "$existing" | grep -v "bmad-loop:$CRON_HASH" | crontab -
      echo "Cron job removed."
    else
      echo "No cron job found for this config (already stopped)."
    fi

    # Update state
    if [[ -f "$STATE_FILE" ]]; then
      tmp=$(mktemp)
      jq '.status = "stopped" | .lastAction = "manually-stopped" | .lastActionAt = "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"' \
        "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
      echo "State set to stopped."
    fi

    echo "BMAD Loop stopped."
    ;;

  # ── PAUSE ────────────────────────────────────────────────────────────────────
  pause)
    if [[ ! -f "$STATE_FILE" ]]; then
      echo "No state file found. Run 'start' first." >&2; exit 1
    fi
    tmp=$(mktemp)
    jq '.status = "paused" | .lastAction = "manually-paused" | .lastActionAt = "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"' \
      "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
    echo "BMAD Loop paused. Cron still fires but will skip all work."
    echo "Resume with: $0 --config $CONFIG_FILE resume"
    ;;

  # ── RESUME ───────────────────────────────────────────────────────────────────
  resume)
    if [[ ! -f "$STATE_FILE" ]]; then
      echo "No state file found. Run 'start' first." >&2; exit 1
    fi
    tmp=$(mktemp)
    jq '.status = "running" | .lastAction = "manually-resumed" | .lastActionAt = "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"' \
      "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
    echo "BMAD Loop resumed."
    ;;

  # ── STATUS ───────────────────────────────────────────────────────────────────
  status)
    if [[ ! -f "$STATE_FILE" ]]; then
      echo "No state file found — loop has not been started yet."
      echo "Run: $0 --config $CONFIG_FILE start"
      exit 0
    fi

    max_review=$(yq '.workflow.max_review_passes' "$CONFIG_FILE")
    max_failures=$(yq '.workflow.max_consecutive_failures' "$CONFIG_FILE")

    st_status=$(jq -r '.status'                 "$STATE_FILE")
    st_story=$(jq -r '.currentStoryNumber'      "$STATE_FILE")
    st_story_key=$(jq -r '.currentStory'        "$STATE_FILE")
    st_step=$(jq -r '.currentStep'              "$STATE_FILE")
    st_rev=$(jq -r '.reviewPassNumber'          "$STATE_FILE")
    st_failures=$(jq -r '.consecutiveFailures'  "$STATE_FILE")
    st_total=$(jq -r '.totalStoriesCompleted'   "$STATE_FILE")
    st_last_action=$(jq -r '.lastAction'        "$STATE_FILE")
    st_last_at=$(jq -r '.lastActionAt'          "$STATE_FILE")
    st_started=$(jq -r '.currentStoryStartedAt' "$STATE_FILE")
    st_file=$(jq -r '.currentStoryFilePath'     "$STATE_FILE")

    # Determine status color indicator
    case "$st_status" in
      running)             indicator="▶" ;;
      paused)              indicator="⏸" ;;
      human-review-needed) indicator="⚠" ;;
      completed)           indicator="✓" ;;
      stopped)             indicator="■" ;;
      *)                   indicator="?" ;;
    esac

    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  BMAD Loop Status — $PROJECT_NAME"
    echo "╠══════════════════════════════════════════════════════════╣"
    printf "║  Status:     %s %s\n" "$indicator" "$st_status"
    printf "║  Story:      %s (%s)\n" "$st_story" "$st_story_key"
    printf "║  Step:       %s\n" "$st_step"
    printf "║  Review:     pass %s/%s\n" "$st_rev" "$max_review"
    printf "║  Failures:   %s/%s consecutive\n" "$st_failures" "$max_failures"
    printf "║  Completed:  %s stories this sprint\n" "$st_total"
    printf "║  Story file: %s\n" "$st_file"
    printf "║  Started:    %s\n" "$st_started"
    printf "║  Last:       %s\n" "$st_last_action"
    printf "║  Last at:    %s\n" "$st_last_at"
    echo "╠══════════════════════════════════════════════════════════╣"
    cron_line=$(crontab -l 2>/dev/null | grep "bmad-loop:$CRON_HASH" || true)
    if [[ -n "$cron_line" ]]; then
      echo "║  Cron:       INSTALLED (every $CRON_INTERVAL min)"
    else
      echo "║  Cron:       NOT INSTALLED (run 'start' to install)"
    fi
    echo "╚══════════════════════════════════════════════════════════╝"
    ;;

  # ── SKIP ─────────────────────────────────────────────────────────────────────
  skip)
    if [[ ! -f "$STATE_FILE" ]]; then
      echo "No state file found. Run 'start' first." >&2; exit 1
    fi

    cur_state=$(cat "$STATE_FILE")
    cur_story=$(echo "$cur_state" | jq -r '.currentStory')
    cur_story_num=$(echo "$cur_state" | jq -r '.currentStoryNumber')
    cur_epic=$(echo "$cur_state" | jq -r '.currentEpic')
    total_completed=$(echo "$cur_state" | jq -r '.totalStoriesCompleted')

    sprint_status_rel=$(yq '.project.sprint_status' "$CONFIG_FILE")
    sprint_status="${PROJECT_DIR}/${sprint_status_rel}"

    if [[ ! -f "$sprint_status" ]]; then
      echo "Sprint status file not found: $sprint_status" >&2; exit 1
    fi

    # Find next story that isn't the current one and isn't done
    next_story=$(
      yq '.development_status | to_entries[] | select(.key | test("^[0-9]+-[0-9]+")) | select(.value != "done") | .key' \
        "$sprint_status" | grep -v "^${cur_story}$" | head -1 || true
    )

    echo "Skipping story $cur_story_num ($cur_story)..."

    if [[ -z "$next_story" || "$next_story" == "null" ]]; then
      tmp=$(mktemp)
      jq '.status = "completed" |
          .lastAction = "manually-skipped-final-story" |
          .lastActionAt = "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"' \
        "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
      echo "No more stories remaining. Marked sprint as completed."
    else
      next_epic=$(echo "$next_story" | sed 's/^\([0-9]*\)-.*/\1/')
      next_epic_part=$(echo "$next_story" | sed 's/^\([0-9]*\)-.*/\1/')
      next_story_part=$(echo "$next_story" | sed 's/^[0-9]*-\([0-9]*\)-.*/\1/')
      next_story_num="${next_epic_part}.${next_story_part}"

      cat > "$STATE_FILE" << SKIPEOF
{
  "status": "running",
  "currentStory": "$next_story",
  "currentStoryNumber": "$next_story_num",
  "currentStoryFilePath": null,
  "currentEpic": $next_epic,
  "currentStep": "create-story",
  "reviewPassNumber": 1,
  "failureCount": 0,
  "consecutiveFailures": 0,
  "lastAction": "manually-skipped-story-${cur_story_num}",
  "lastActionAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "lastExitCode": null,
  "totalStoriesCompleted": $total_completed,
  "currentStoryStartedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
SKIPEOF

      echo "Advanced to story $next_story_num ($next_story)"
    fi

    # Append to activity log if it exists
    if [[ -f "$LOG_FILE" ]]; then
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) | MANUAL_SKIP | story:$cur_story_num | next:${next_story_num:-none}" >> "$LOG_FILE"
    fi
    ;;

  # ── LOGS ─────────────────────────────────────────────────────────────────────
  logs)
    if [[ ! -f "$LOG_FILE" ]]; then
      echo "Log file not found: $LOG_FILE"
      echo "The loop has not run yet, or the log path in config is wrong."
      exit 0
    fi
    echo "Tailing: $LOG_FILE (Ctrl-C to stop)"
    echo "──────────────────────────────────────────────────────────"
    tail -f "$LOG_FILE"
    ;;

  # ── RUN-ONCE ─────────────────────────────────────────────────────────────────
  run-once)
    echo "Running single cycle for project '$PROJECT_NAME'..."
    bash "$LOOP_SCRIPT" "$CONFIG_FILE"
    echo ""
    echo "Cycle complete. Current status:"
    if [[ -f "$STATE_FILE" ]]; then
      jq '{status, currentStoryNumber, currentStep, consecutiveFailures, lastAction}' "$STATE_FILE"
    fi
    ;;

  # ── RESET ────────────────────────────────────────────────────────────────────
  reset)
    if [[ -f "$STATE_FILE" ]]; then
      read -r -p "Reset state file for '$PROJECT_NAME'? This will re-initialize from sprint-status.yaml. [y/N] " confirm
      if [[ "$confirm" =~ ^[Yy]$ ]]; then
        rm -f "$STATE_FILE"
        echo "State file removed. Next run will reinitialize from sprint-status.yaml."
      else
        echo "Reset cancelled."
      fi
    else
      echo "No state file found — nothing to reset."
    fi
    ;;

  *)
    echo "Unknown command: $COMMAND" >&2
    usage
    exit 1
    ;;
esac
