#!/usr/bin/env bash
# GeoWake Autopilot worker — picks one task from the queue, delegates it to a
# free-tier CLI agent (opencode → fallback → crush), validates the result, and
# commits it to an autopilot/<id> branch for human review. Never touches main
# branches, never pushes.
set -euo pipefail
source "$(dirname "$0")/../config.sh"

mkdir -p "$QUEUE_DIR"/{pending,running,done,failed} "$LOG_DIR" "$REPORT_DIR"
date +%s > "$HEARTBEAT_FILE"

# ── single-instance lock ─────────────────────────────────────────────────────
exec 9>"$LOCK_FILE"
if ! flock -n 9; then echo "worker already running"; exit 0; fi
echo $$ >&9

cd "$REPO_ROOT"

# Require a clean tree: the worker must never mix its diff with human WIP.
if [[ -n "$(git status --porcelain -- lib test geowake-server packages android)" ]]; then
  echo "working tree dirty in code paths — skipping run (human WIP has priority)"
  exit 0
fi

# ── pick task: lowest priority number, then oldest ───────────────────────────
task_file=$(ls -1 "$QUEUE_DIR/pending" 2>/dev/null | sort | head -1 || true)
[[ -z "$task_file" ]] && { echo "queue empty"; exit 0; }
src="$QUEUE_DIR/pending/$task_file"; run="$QUEUE_DIR/running/$task_file"
mv "$src" "$run"

get() { grep -m1 "^$1:" "$run" | sed "s/^$1:[[:space:]]*//" || true; }
id=$(get id); [[ -z "$id" ]] && id="${task_file%.md}"
minutes=$(get max_minutes); [[ -z "$minutes" ]] && minutes=$MAX_TASK_MINUTES
(( minutes > MAX_TASK_MINUTES )) && minutes=$MAX_TASK_MINUTES
model=$(get model); [[ -z "$model" ]] && model=$MODEL_CODE
test_cmd=$(get test_cmd)
body=$(awk 'flag{print} /^---[[:space:]]*$/{n++; if(n==2) flag=1}' "$run")
[[ -z "$body" ]] && body=$(cat "$run")

log="$LOG_DIR/$id.log"
base_branch=$(git rev-parse --abbrev-ref HEAD)
work_branch="autopilot/$id"
git checkout -b "$work_branch" >>"$log" 2>&1

fail() { # $1 = reason
  echo "FAILED: $1" | tee -a "$log"
  git checkout -- . >>"$log" 2>&1 || true
  git clean -fd lib test geowake-server packages >>"$log" 2>&1 || true
  git checkout "$base_branch" >>"$log" 2>&1
  git branch -D "$work_branch" >>"$log" 2>&1 || true
  mv "$run" "$QUEUE_DIR/failed/$task_file"
  printf '%s\nreason: %s\n' "$(date -Is)" "$1" >> "$QUEUE_DIR/failed/$task_file"
  exit 0
}

# ── delegate: walk the model ladder ─────────────────────────────────────────
prompt="$GUARDRAIL_PREAMBLE
$body"
ok=false
for m in "$model" "$MODEL_HEAVY" "crush"; do
  echo "=== attempt with $m at $(date -Is) ===" >> "$log"
  if [[ "$m" == "crush" ]]; then
    if timeout "${minutes}m" crush run -q "$prompt" >>"$log" 2>&1; then ok=true; break; fi
  else
    if timeout "${minutes}m" opencode run -m "$m" "$prompt" >>"$log" 2>&1; then ok=true; break; fi
  fi
  echo "=== $m failed/timed out ===" >> "$log"
done
$ok || fail "all model attempts failed or timed out"

# ── validate ─────────────────────────────────────────────────────────────────
if [[ -z "$(git status --porcelain)" ]]; then
  echo "no diff produced (task may be analysis-only — see log)" >> "$log"
  git checkout "$base_branch" >>"$log" 2>&1; git branch -D "$work_branch" >>"$log" 2>&1 || true
  mv "$run" "$QUEUE_DIR/done/$task_file"; exit 0
fi

# invariant paths untouched?
for p in "${INVARIANT_PATHS[@]}"; do
  if git status --porcelain -- "$p" | grep -q .; then fail "touched invariant path: $p"; fi
done
# invariant patterns not weakened?
for pat in "${INVARIANT_PATTERNS[@]}"; do
  if git diff -U0 | grep -E "^-.*$pat" | grep -vq "^---"; then fail "diff removes a line containing invariant symbol: $pat"; fi
done

flutter analyze lib/ --no-fatal-infos >>"$log" 2>&1 || fail "flutter analyze broken by change"
if [[ -n "$test_cmd" ]]; then
  bash -c "$test_cmd" >>"$log" 2>&1 || fail "task test_cmd failed: $test_cmd"
else
  flutter test test/ekf/replay_harness_test.dart >>"$log" 2>&1 || fail "never-late gate failed"
fi

git add -A
git commit -m "autopilot($id): $(head -c 60 <<<"$body" | tr '\n' ' ')" \
  -m "Delegated to free-tier CLI agent; validated: analyze + ${test_cmd:-never-late gate}." \
  -m "Co-Authored-By: GeoWake Autopilot <autopilot@geowake.app>" >>"$log" 2>&1

git checkout "$base_branch" >>"$log" 2>&1
mv "$run" "$QUEUE_DIR/done/$task_file"
{
  echo "## $id — $(date -Is)"
  echo "branch: $work_branch (awaiting human review: git diff $base_branch..$work_branch)"
  echo "log: $log"
  echo
} >> "$REPORT_DIR/$(date +%F).md"
echo "DONE: $work_branch ready for review"
