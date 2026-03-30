#!/usr/bin/env bash
set -euo pipefail

# Ensure PATH includes common tool locations (cron uses a minimal PATH)
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:$HOME/.local/bin:$PATH"
[ -s "$HOME/.nvm/nvm.sh" ] && source "$HOME/.nvm/nvm.sh" 2>/dev/null

# bmad-loop.sh — BMAD V6 automated workflow orchestrator
# Designed to be called by cron; runs ONE action per invocation.

# ─── ARGUMENT PARSING ──────────────────────────────────────────────────────────
DRY_RUN=false
CONFIG_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --config|-c) CONFIG_FILE="$2"; shift 2 ;;
    -*) echo "Unknown flag: $1" >&2; exit 1 ;;
    *) CONFIG_FILE="$1"; shift ;;
  esac
done

if [[ -z "$CONFIG_FILE" ]]; then
  echo "Usage: bmad-loop.sh [--dry-run] /path/to/bmad-loop.config.yaml" >&2
  exit 1
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Config file not found: $CONFIG_FILE" >&2
  exit 1
fi

# Resolve to absolute path
CONFIG_FILE="$(cd "$(dirname "$CONFIG_FILE")" && pwd)/$(basename "$CONFIG_FILE")"

# ─── PLATFORM DETECTION ────────────────────────────────────────────────────────
IS_MACOS=false
[[ "$(uname)" == "Darwin" ]] && IS_MACOS=true

# ─── DEPENDENCY CHECK ──────────────────────────────────────────────────────────
missing_deps=false
for dep in claude jq yq git; do
  if ! command -v "$dep" >/dev/null 2>&1; then
    echo "ERROR: Required dependency '$dep' not found." >&2
    case "$dep" in
      yq)     echo "  Install: brew install yq" >&2 ;;
      jq)     echo "  Install: brew install jq" >&2 ;;
      claude) echo "  Install: npm install -g @anthropic-ai/claude-code" >&2 ;;
    esac
    missing_deps=true
  fi
done
$missing_deps && exit 1

# Detect timeout command (needs coreutils on macOS)
TIMEOUT_CMD=""
if command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_CMD="gtimeout"
elif command -v timeout >/dev/null 2>&1; then
  TIMEOUT_CMD="timeout"
else
  echo "WARNING: No timeout command found. Install coreutils: brew install coreutils" >&2
fi

# ─── PLATFORM HELPERS ──────────────────────────────────────────────────────────
config_hash() {
  if $IS_MACOS; then
    printf '%s' "$1" | md5
  else
    printf '%s' "$1" | md5sum | cut -d' ' -f1
  fi
}

sed_inplace() {
  if $IS_MACOS; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

run_with_timeout() {
  local secs="$1"; shift
  if [[ -n "$TIMEOUT_CMD" ]]; then
    "$TIMEOUT_CMD" "$secs" "$@"
  else
    "$@"
  fi
}

# ─── LOCK FILE (prevent overlapping runs) ──────────────────────────────────────
LOCK_DIR="/tmp/bmad-loop-$(config_hash "$CONFIG_FILE").lock"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "Another instance is already running (lock: $LOCK_DIR). Exiting."
  exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT INT TERM

# ─── READ CONFIG ───────────────────────────────────────────────────────────────
PROJECT_DIR=$(yq '.project.path' "$CONFIG_FILE")
PROJECT_NAME=$(yq '.project.name' "$CONFIG_FILE")
SPRINT_STATUS_REL=$(yq '.project.sprint_status' "$CONFIG_FILE")
SPRINT_STATUS="${PROJECT_DIR}/${SPRINT_STATUS_REL}"
STORY_LOCATION_REL=$(yq '.project.story_location' "$CONFIG_FILE")
STORY_LOCATION="${PROJECT_DIR}/${STORY_LOCATION_REL}"
STATE_FILE="${PROJECT_DIR}/_bmad-output/implementation-artifacts/bmad-loop-state.json"

LOG_FILE_REL=$(yq '.notifications.log_file' "$CONFIG_FILE")
LOG_FILE="${PROJECT_DIR}/${LOG_FILE_REL}"

MODEL_CREATE=$(yq '.models.create_story' "$CONFIG_FILE")
MODEL_REVIEW=$(yq '.models.code_review' "$CONFIG_FILE")
MODEL_DEV_DEFAULT=$(yq '.models.dev_story_default' "$CONFIG_FILE")

BASE_BRANCH=$(yq '.branch_strategy.base_branch' "$CONFIG_FILE")
FEATURE_PREFIX=$(yq '.branch_strategy.feature_branch_prefix' "$CONFIG_FILE")
MERGE_AFTER_REVIEW=$(yq '.branch_strategy.merge_after_review' "$CONFIG_FILE")
PUSH_AFTER_MERGE=$(yq '.branch_strategy.push_after_merge' "$CONFIG_FILE")

TIMEOUT_CREATE=$(yq '.timeouts.create_story_seconds' "$CONFIG_FILE")
TIMEOUT_DEV=$(yq '.timeouts.dev_story_seconds' "$CONFIG_FILE")
TIMEOUT_REVIEW=$(yq '.timeouts.code_review_seconds' "$CONFIG_FILE")

BUDGET_CREATE=$(yq '.budget.create_story_max_usd' "$CONFIG_FILE")
BUDGET_DEV=$(yq '.budget.dev_story_max_usd' "$CONFIG_FILE")
BUDGET_REVIEW=$(yq '.budget.code_review_max_usd' "$CONFIG_FILE")

MAX_REVIEW_PASSES=$(yq '.workflow.max_review_passes' "$CONFIG_FILE")
MAX_FAILURES=$(yq '.workflow.max_consecutive_failures' "$CONFIG_FILE")
UPDATE_GITHUB=$(yq '.workflow.update_github_issues' "$CONFIG_FILE")
EXTRA_DEV_INSTRUCTIONS=$(yq '.workflow.extra_dev_instructions' "$CONFIG_FILE")
EXTRA_REVIEW_INSTRUCTIONS=$(yq '.workflow.extra_review_instructions' "$CONFIG_FILE")

# Ensure output dirs exist
mkdir -p "$(dirname "$STATE_FILE")"
mkdir -p "$(dirname "$LOG_FILE")"

# ─── HELPERS ───────────────────────────────────────────────────────────────────

log_activity() {
  local event="$1" details="$2"
  local msg
  msg="$(date -u +%Y-%m-%dT%H:%M:%SZ) | $event | $details"
  echo "$msg" >> "$LOG_FILE"
  echo "$msg"
}

get_state() {
  [[ -f "$STATE_FILE" ]] && cat "$STATE_FILE" || echo "{}"
}

update_state() {
  local key="$1" value="$2"
  local tmp
  tmp=$(mktemp)
  jq --arg k "$key" --arg v "$value" '.[$k] = $v' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

get_model_for_story() {
  local story_key="$1" epic_num="$2"
  local story_model epic_model
  story_model=$(yq ".models.story_overrides.\"${story_key}\" // \"\"" "$CONFIG_FILE")
  if [[ -n "$story_model" && "$story_model" != "null" && "$story_model" != '""' && "$story_model" != "" ]]; then
    echo "$story_model"; return
  fi
  epic_model=$(yq ".models.epic_overrides.\"epic-${epic_num}\" // \"\"" "$CONFIG_FILE")
  if [[ -n "$epic_model" && "$epic_model" != "null" && "$epic_model" != '""' && "$epic_model" != "" ]]; then
    echo "$epic_model"; return
  fi
  echo "$MODEL_DEV_DEFAULT"
}

get_story_status() {
  local story_key="$1"
  yq ".development_status.\"${story_key}\"" "$SPRINT_STATUS"
}

get_next_story() {
  yq '.development_status | to_entries[] | select(.key | test("^[0-9]+-[0-9]+")) | select(.value != "done") | .key' \
    "$SPRINT_STATUS" | head -1
}

get_epic_number() {
  echo "$1" | sed 's/^\([0-9]*\)-.*/\1/'
}

get_story_number() {
  local story_key="$1"
  local epic story
  epic=$(echo "$story_key" | sed 's/^\([0-9]*\)-.*/\1/')
  story=$(echo "$story_key" | sed 's/^[0-9]*-\([0-9]*\)-.*/\1/')
  echo "${epic}.${story}"
}

get_story_name_pretty() {
  # "2-1-figure-catalog-view-empty-state" → "figure catalog view, empty state"
  local name
  name=$(echo "$1" | sed 's/^[0-9]*-[0-9]*-//' | tr '-' ' ')
  echo "$name" | sed 's/ /, /3'
}

update_sprint_status() {
  local story_key="$1" new_status="$2"
  sed_inplace "s/  ${story_key}: .*/  ${story_key}: ${new_status}/" "$SPRINT_STATUS"
}

# Sets globals CLAUDE_OUTPUT and CLAUDE_EXIT_CODE
CLAUDE_OUTPUT=""
CLAUDE_EXIT_CODE=0

run_claude_p() {
  local prompt="$1" model="$2" timeout_secs="$3" budget="$4"
  local output_file
  output_file=$(mktemp)
  CLAUDE_EXIT_CODE=0

  if $DRY_RUN; then
    echo "[DRY-RUN] Would run claude -p with model=$model timeout=${timeout_secs}s budget=\$${budget}"
    echo "[DRY-RUN] Prompt (first 200 chars): ${prompt:0:200}"
    CLAUDE_OUTPUT="[DRY-RUN output]"
    rm -f "$output_file"
    return
  fi

  cd "$PROJECT_DIR"
  run_with_timeout "$timeout_secs" claude -p "$prompt" \
    --model "$model" \
    --dangerously-skip-permissions \
    --max-budget-usd "$budget" \
    --output-format text \
    > "$output_file" 2>&1 || CLAUDE_EXIT_CODE=$?

  CLAUDE_OUTPUT=$(cat "$output_file")
  rm -f "$output_file"
}

close_github_issue() {
  local story_key="$1" story_number="$2"
  [[ "$UPDATE_GITHUB" != "true" ]] && return 0
  $DRY_RUN && { echo "[DRY-RUN] Would close GitHub issue for story $story_number"; return 0; }

  cd "$PROJECT_DIR"
  claude -p "Find the GitHub issue for story $story_number ($story_key) and close it with a comment saying 'Completed via automated BMAD workflow'. Use the GitHub MCP server tools available to this project." \
    --model haiku \
    --dangerously-skip-permissions \
    --max-budget-usd 0.50 \
    > /dev/null 2>&1 || true
}

do_merge_and_cleanup() {
  local story_num="$1" feature_branch="$2"

  if $DRY_RUN; then
    echo "[DRY-RUN] Would merge $feature_branch into $BASE_BRANCH and delete branch"
    return 0
  fi

  cd "$PROJECT_DIR"
  git checkout "$BASE_BRANCH"
  git merge "$feature_branch" --no-ff -m "merge: story $story_num into $BASE_BRANCH"

  if [[ "$PUSH_AFTER_MERGE" == "true" ]]; then
    git push origin "$BASE_BRANCH"
  fi

  git branch -d "$feature_branch" 2>/dev/null || true
  git push origin --delete "$feature_branch" 2>/dev/null || true

  log_activity "MERGE" "story:$story_num | branch:$feature_branch | into:$BASE_BRANCH"
}

advance_to_next_story() {
  local current_story_num="$1" epic_num="$2" reason="$3"
  local state next_story next_epic next_story_num total_completed new_total

  state=$(get_state)
  total_completed=$(echo "$state" | jq -r '.totalStoriesCompleted')
  new_total=$(( total_completed + 1 ))
  next_story=$(get_next_story)

  if [[ -n "$next_story" && "$next_story" != "null" ]]; then
    next_epic=$(get_epic_number "$next_story")
    next_story_num=$(get_story_number "$next_story")

    if [[ "$next_epic" != "$epic_num" ]]; then
      log_activity "EPIC_DONE" "epic:$epic_num"
      $DRY_RUN || update_sprint_status "epic-$epic_num" "done"
    fi

    if $DRY_RUN; then
      echo "[DRY-RUN] Would advance state to next story: $next_story_num ($next_story)"
    else
      cat > "$STATE_FILE" << STATEOF
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
  "lastAction": "$reason",
  "lastActionAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "lastExitCode": null,
  "totalStoriesCompleted": $new_total,
  "currentStoryStartedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
STATEOF
    fi

    log_activity "ADVANCE" "from:$current_story_num | to:$next_story_num"
  else
    if $DRY_RUN; then
      echo "[DRY-RUN] Would mark sprint as completed (total: $new_total)"
    else
      update_state "status" "completed"
      update_state "totalStoriesCompleted" "$new_total"
    fi
    log_activity "SPRINT_DONE" "All stories completed | total:$new_total"
  fi
}

complete_story() {
  local story_key="$1" story_num="$2" epic_num="$3" review_pass="$4" reason="$5"
  local feature_branch="${FEATURE_PREFIX}story-${story_num}"

  $DRY_RUN || update_sprint_status "$story_key" "done"

  # Commit any lingering staged changes
  if ! $DRY_RUN; then
    cd "$PROJECT_DIR"
    git add -A
    git diff --cached --quiet || git commit -m "fix: code review cleanup for story $story_num"
  fi

  log_activity "STORY_DONE" "story:$story_num | review_passes:$review_pass | reason:$reason"

  if [[ "$MERGE_AFTER_REVIEW" == "true" ]]; then
    do_merge_and_cleanup "$story_num" "$feature_branch"
  fi

  close_github_issue "$story_key" "$story_num"
  advance_to_next_story "$story_num" "$epic_num" "advanced-after-$reason"
}

handle_failure() {
  local story_num="$1" step="$2" reason="$3" exit_code="${4:-}"
  local failure_count new_failures

  failure_count=$(get_state | jq -r '.consecutiveFailures')
  new_failures=$(( failure_count + 1 ))

  $DRY_RUN || {
    update_state "consecutiveFailures" "$new_failures"
    update_state "lastAction" "failed-${step}"
    [[ -n "$exit_code" ]] && update_state "lastExitCode" "$exit_code"
  }

  log_activity "FAILURE" "story:$story_num | step:$step | reason:$reason | failures:$new_failures/$MAX_FAILURES"

  if [[ "$new_failures" -ge "$MAX_FAILURES" ]]; then
    $DRY_RUN || update_state "status" "human-review-needed"
    log_activity "STALL" "story:$story_num | action:paused-for-human-review"
  fi
}

# ─── INITIALIZE STATE FILE IF NEEDED ──────────────────────────────────────────
if [[ ! -f "$STATE_FILE" ]]; then
  NEXT_STORY=$(get_next_story)

  if [[ -z "$NEXT_STORY" || "$NEXT_STORY" == "null" ]]; then
    echo "No stories found in sprint-status. Nothing to do."
    exit 0
  fi

  INIT_EPIC=$(get_epic_number "$NEXT_STORY")
  INIT_STORY_NUM=$(get_story_number "$NEXT_STORY")

  if ! $DRY_RUN; then
    cat > "$STATE_FILE" << INITEOF
{
  "status": "running",
  "currentStory": "$NEXT_STORY",
  "currentStoryNumber": "$INIT_STORY_NUM",
  "currentStoryFilePath": null,
  "currentEpic": $INIT_EPIC,
  "currentStep": "create-story",
  "reviewPassNumber": 1,
  "failureCount": 0,
  "consecutiveFailures": 0,
  "lastAction": "initialized",
  "lastActionAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "lastExitCode": null,
  "totalStoriesCompleted": 0,
  "currentStoryStartedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
INITEOF
  fi

  log_activity "INIT" "story:$INIT_STORY_NUM | step:create-story | queue-start:$NEXT_STORY"
fi

# ─── READ CURRENT STATE ────────────────────────────────────────────────────────
STATE=$(get_state)
STATUS=$(echo "$STATE" | jq -r '.status')
CURRENT_STORY=$(echo "$STATE" | jq -r '.currentStory')
CURRENT_STEP=$(echo "$STATE" | jq -r '.currentStep')
REVIEW_PASS=$(echo "$STATE" | jq -r '.reviewPassNumber')
FAILURE_COUNT=$(echo "$STATE" | jq -r '.consecutiveFailures')
STORY_FILE_PATH=$(echo "$STATE" | jq -r '.currentStoryFilePath')
CURRENT_STORY_NUM=$(echo "$STATE" | jq -r '.currentStoryNumber')
EPIC_NUM=$(get_epic_number "$CURRENT_STORY")

# ─── CHECK STATUS ─────────────────────────────────────────────────────────────
case "$STATUS" in
  paused)
    log_activity "CRON_SKIP" "story:$CURRENT_STORY_NUM | reason:paused"
    exit 0
    ;;
  human-review-needed)
    log_activity "CRON_SKIP" "story:$CURRENT_STORY_NUM | reason:human-review-needed"
    exit 0
    ;;
  completed)
    log_activity "CRON_SKIP" "reason:all-stories-completed"
    exit 0
    ;;
esac

if [[ -z "$CURRENT_STORY" || "$CURRENT_STORY" == "null" ]]; then
  $DRY_RUN || update_state "status" "completed"
  log_activity "SPRINT_DONE" "No more stories"
  exit 0
fi

$DRY_RUN && echo "[DRY-RUN] Story=$CURRENT_STORY_NUM Step=$CURRENT_STEP ReviewPass=$REVIEW_PASS"

# ─── MAIN DISPATCH ────────────────────────────────────────────────────────────
case "$CURRENT_STEP" in

  # ── CREATE-STORY ────────────────────────────────────────────────────────────
  "create-story")
    STORY_STATUS=$(get_story_status "$CURRENT_STORY")

    # If story already exists past backlog, find its file and skip create
    if [[ "$STORY_STATUS" != "backlog" ]]; then
      STORY_FILE=$(find "$STORY_LOCATION" -name "${CURRENT_STORY}.md" -type f 2>/dev/null | head -1 || true)
      if [[ -n "$STORY_FILE" ]]; then
        $DRY_RUN || {
          update_state "currentStep" "dev-story"
          update_state "currentStoryFilePath" "$STORY_FILE"
        }
        log_activity "SKIP" "story:$CURRENT_STORY_NUM | step:create-story | reason:already-${STORY_STATUS}"
        exit 0
      fi
    fi

    log_activity "CRON_FIRE" "story:$CURRENT_STORY_NUM | step:create-story | model:$MODEL_CREATE"

    PROMPT="Run /bmad-create-story for story ${CURRENT_STORY}.
When presented with interactive checkpoints like [a] [c] [p] [y], choose 'c' to continue.
When asked yes/no questions, answer 'y'.
Complete the entire workflow autonomously. Do not stop for user input.
At the end, output the exact file path of the created story file on a line starting with BMAD_RESULT:CREATE_COMPLETE:"

    run_claude_p "$PROMPT" "$MODEL_CREATE" "$TIMEOUT_CREATE" "$BUDGET_CREATE"

    if [[ "$CLAUDE_EXIT_CODE" -eq 0 ]]; then
      STORY_FILE=$(find "$STORY_LOCATION" -name "${CURRENT_STORY}.md" -type f 2>/dev/null | head -1 || true)

      if [[ -n "$STORY_FILE" ]]; then
        $DRY_RUN || {
          update_state "currentStep" "dev-story"
          update_state "currentStoryFilePath" "$STORY_FILE"
          update_state "consecutiveFailures" "0"
          update_state "lastAction" "create-story-complete"

          # Ensure sprint-status reflects ready-for-dev
          STORY_STATUS=$(get_story_status "$CURRENT_STORY")
          [[ "$STORY_STATUS" == "backlog" ]] && update_sprint_status "$CURRENT_STORY" "ready-for-dev"
        }
        log_activity "TRANSITION" "story:$CURRENT_STORY_NUM | from:create-story | to:dev-story | file:$STORY_FILE"
      else
        handle_failure "$CURRENT_STORY_NUM" "create-story" "no-story-file-found"
      fi
    else
      handle_failure "$CURRENT_STORY_NUM" "create-story" "claude-exit-${CLAUDE_EXIT_CODE}" "$CLAUDE_EXIT_CODE"
    fi
    ;;

  # ── DEV-STORY ───────────────────────────────────────────────────────────────
  "dev-story")
    DEV_MODEL=$(get_model_for_story "$CURRENT_STORY" "$EPIC_NUM")
    log_activity "CRON_FIRE" "story:$CURRENT_STORY_NUM | step:dev-story | model:$DEV_MODEL"

    FEATURE_BRANCH="${FEATURE_PREFIX}story-${CURRENT_STORY_NUM}"

    if ! $DRY_RUN; then
      cd "$PROJECT_DIR"
      git checkout "$BASE_BRANCH" 2>/dev/null || true
      git pull origin "$BASE_BRANCH" 2>/dev/null || true

      if git rev-parse --verify "$FEATURE_BRANCH" >/dev/null 2>&1; then
        git checkout "$FEATURE_BRANCH"
      else
        git checkout -b "$FEATURE_BRANCH"
      fi
    else
      echo "[DRY-RUN] Would checkout/create branch: $FEATURE_BRANCH"
    fi

    STORY_NAME_PRETTY=$(get_story_name_pretty "$CURRENT_STORY")

    PROMPT="Run /bmad-dev-story for story ${CURRENT_STORY}.
Story file: ${STORY_FILE_PATH}

${EXTRA_DEV_INSTRUCTIONS}

Complete ALL tasks and subtasks in the story file. Run ALL tests and ensure they pass.
When presented with interactive checkpoints, choose to continue.
Do not stop for user input — complete the entire workflow autonomously.
If you encounter a HALT condition, output: BMAD_RESULT:HALT:reason

After successful completion, commit your work with this exact message:
feat: story ${CURRENT_STORY_NUM} — ${STORY_NAME_PRETTY}

Then output: BMAD_RESULT:DEV_COMPLETE
If tests fail after implementation, output: BMAD_RESULT:DEV_TESTS_FAILED:details"

    run_claude_p "$PROMPT" "$DEV_MODEL" "$TIMEOUT_DEV" "$BUDGET_DEV"

    if echo "$CLAUDE_OUTPUT" | grep -q "BMAD_RESULT:HALT"; then
      HALT_REASON=$(echo "$CLAUDE_OUTPUT" | grep "BMAD_RESULT:HALT" | sed 's/.*BMAD_RESULT:HALT://' | head -1)
      $DRY_RUN || {
        update_state "status" "human-review-needed"
        update_state "lastAction" "halt:${HALT_REASON}"
      }
      log_activity "HALT" "story:$CURRENT_STORY_NUM | reason:$HALT_REASON"
      exit 0
    fi

    if [[ "$CLAUDE_EXIT_CODE" -eq 0 ]]; then
      $DRY_RUN || update_sprint_status "$CURRENT_STORY" "review"

      # Verify commit exists; if not, commit manually
      if ! $DRY_RUN; then
        cd "$PROJECT_DIR"
        if ! git log --oneline -1 2>/dev/null | grep -q "story $CURRENT_STORY_NUM"; then
          git add -A
          git commit -m "feat: story ${CURRENT_STORY_NUM} — ${STORY_NAME_PRETTY}" || true
          NOTE="note:manual-commit"
        else
          NOTE="note:agent-committed"
        fi
      fi

      $DRY_RUN || {
        update_state "currentStep" "code-review"
        update_state "reviewPassNumber" "1"
        update_state "consecutiveFailures" "0"
        update_state "lastAction" "dev-story-complete"
      }
      log_activity "TRANSITION" "story:$CURRENT_STORY_NUM | from:dev-story | to:code-review | model:$DEV_MODEL | ${NOTE:-}"
    else
      handle_failure "$CURRENT_STORY_NUM" "dev-story" "claude-exit-${CLAUDE_EXIT_CODE}" "$CLAUDE_EXIT_CODE"
    fi
    ;;

  # ── CODE-REVIEW ─────────────────────────────────────────────────────────────
  "code-review")
    log_activity "CRON_FIRE" "story:$CURRENT_STORY_NUM | step:code-review | pass:${REVIEW_PASS}/${MAX_REVIEW_PASSES} | model:$MODEL_REVIEW"

    STORY_NAME_PRETTY=$(get_story_name_pretty "$CURRENT_STORY")

    PROMPT="Run /bmad-code-review for story ${CURRENT_STORY}.
Story file: ${STORY_FILE_PATH}
This is review pass ${REVIEW_PASS} of max ${MAX_REVIEW_PASSES}.

${EXTRA_REVIEW_INSTRUCTIONS}

When asked what to review, review the changes for this story.
When asked about a spec file, use ${STORY_FILE_PATH}.
When presented with findings and asked how to handle them, choose option 1 (fix automatically).
When asked about decision-needed items, fix them using your best judgment.
Complete the entire review autonomously.

After completion, if fixes were made, commit them with:
fix: code review fixes for story ${CURRENT_STORY_NUM} (pass ${REVIEW_PASS})

Then output EXACTLY one of:
BMAD_RESULT:REVIEW_CLEAN
BMAD_RESULT:REVIEW_FIXED:count"

    run_claude_p "$PROMPT" "$MODEL_REVIEW" "$TIMEOUT_REVIEW" "$BUDGET_REVIEW"

    if [[ "$CLAUDE_EXIT_CODE" -ne 0 ]]; then
      handle_failure "$CURRENT_STORY_NUM" "code-review" "claude-exit-${CLAUDE_EXIT_CODE}" "$CLAUDE_EXIT_CODE"
    elif echo "$CLAUDE_OUTPUT" | grep -q "BMAD_RESULT:REVIEW_CLEAN"; then
      log_activity "REVIEW_DONE" "story:$CURRENT_STORY_NUM | outcome:clean | pass:${REVIEW_PASS}/${MAX_REVIEW_PASSES}"
      complete_story "$CURRENT_STORY" "$CURRENT_STORY_NUM" "$EPIC_NUM" "$REVIEW_PASS" "review-clean"
    elif echo "$CLAUDE_OUTPUT" | grep -q "BMAD_RESULT:REVIEW_FIXED"; then
      FIX_COUNT=$(echo "$CLAUDE_OUTPUT" | grep "BMAD_RESULT:REVIEW_FIXED" | sed 's/.*BMAD_RESULT:REVIEW_FIXED://' | head -1)

      # Commit any fixes the agent made
      if ! $DRY_RUN; then
        cd "$PROJECT_DIR"
        git add -A
        git diff --cached --quiet || \
          git commit -m "fix: code review fixes for story $CURRENT_STORY_NUM (pass $REVIEW_PASS)"
      fi

      log_activity "REVIEW_DONE" "story:$CURRENT_STORY_NUM | outcome:fixed:$FIX_COUNT | pass:${REVIEW_PASS}/${MAX_REVIEW_PASSES}"

      if [[ "$REVIEW_PASS" -ge "$MAX_REVIEW_PASSES" ]]; then
        log_activity "REVIEW_MAX" "story:$CURRENT_STORY_NUM | advancing-after-max-passes"
        complete_story "$CURRENT_STORY" "$CURRENT_STORY_NUM" "$EPIC_NUM" "$REVIEW_PASS" "review-max-passes"
      else
        NEW_PASS=$(( REVIEW_PASS + 1 ))
        $DRY_RUN || {
          update_state "reviewPassNumber" "$NEW_PASS"
          update_state "consecutiveFailures" "0"
          update_state "lastAction" "review-fixed-queued-rerun"
        }
        log_activity "REVIEW_RERUN" "story:$CURRENT_STORY_NUM | next-pass:${NEW_PASS}/${MAX_REVIEW_PASSES}"
      fi
    else
      # Unparseable output — fall back to checking sprint-status
      STORY_STATUS=$(get_story_status "$CURRENT_STORY")
      if [[ "$STORY_STATUS" == "done" ]]; then
        log_activity "REVIEW_DONE" "story:$CURRENT_STORY_NUM | outcome:done-via-status-fallback | pass:$REVIEW_PASS"
        complete_story "$CURRENT_STORY" "$CURRENT_STORY_NUM" "$EPIC_NUM" "$REVIEW_PASS" "review-done-status-fallback"
      else
        handle_failure "$CURRENT_STORY_NUM" "code-review" "unparseable-output"
      fi
    fi
    ;;

  *)
    echo "ERROR: Unknown step '$CURRENT_STEP' in state file." >&2
    log_activity "ERROR" "story:$CURRENT_STORY_NUM | unknown-step:$CURRENT_STEP"
    exit 1
    ;;
esac

$DRY_RUN || update_state "lastActionAt" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
