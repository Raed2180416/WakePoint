#!/usr/bin/env bash
# GeoWake Autopilot nightly — full health pass. Runs the complete quality gate,
# summarizes repo/business state, and auto-files fix tasks into the queue when
# something is red. Cheap, deterministic, no LLM needed for the checks
# themselves; an LLM triage summary is attempted best-effort at the end.
set -uo pipefail
source "$(dirname "$0")/../config.sh"
mkdir -p "$REPORT_DIR" "$QUEUE_DIR/pending"
cd "$REPO_ROOT"

R="$REPORT_DIR/nightly-$(date +%F).md"
status=OK
say() { echo "$@" | tee -a "$R"; }

echo "# GeoWake nightly — $(date -Is)" > "$R"

run_gate() { # $1 name, $2 command
  local out; out=$(mktemp)
  if bash -c "$2" >"$out" 2>&1; then
    say "- ✅ $1"
  else
    status=FAIL
    say "- ❌ $1 — tail:"
    tail -15 "$out" | sed 's/^/      /' >> "$R"
    # auto-file a fix task (idempotent per day+gate)
    local tf="$QUEUE_DIR/pending/$(date +%F)-fix-${1// /_}.md"
    if [[ ! -f "$tf" && ! -f "$QUEUE_DIR/running/$(basename "$tf")" ]]; then
      {
        echo "---"
        echo "id: $(date +%F)-fix-${1// /_}"
        echo "max_minutes: 40"
        echo "model: $MODEL_CODE"
        echo "test_cmd: $2"
        echo "---"
        echo "The nightly gate '$1' failed. Command: $2"
        echo "Failure output tail:"
        tail -40 "$out"
        echo
        echo "Diagnose the root cause and fix it with a minimal diff. Re-run the command to confirm green."
      } > "$tf"
      say "      → filed task $(basename "$tf")"
    fi
  fi
  rm -f "$out"
}

say "## Quality gates"
run_gate "flutter analyze" "flutter analyze lib/ --no-fatal-infos"
run_gate "never-late replay harness" "flutter test test/ekf/replay_harness_test.dart"
run_gate "reachability suite" "flutter test test/reachability/"
run_gate "full flutter suite" "flutter test"
run_gate "server jest suite" "cd geowake-server && npx jest --silent"

say ""
say "## Repo state"
say "- branch: $(git rev-parse --abbrev-ref HEAD) @ $(git log -1 --format='%h %s')"
say "- dirty files: $(git status --porcelain | wc -l)"
say "- autopilot branches awaiting review: $(git branch --list 'autopilot/*' | wc -l)"
say "- queue: pending=$(ls "$QUEUE_DIR/pending" 2>/dev/null | wc -l) failed=$(ls "$QUEUE_DIR/failed" 2>/dev/null | wc -l)"
say "- disk free: $(df -h "$REPO_ROOT" | awk 'NR==2{print $4}')"

# Best-effort LLM triage summary (free tier, hard timeout, failure is fine)
if [[ "$status" == "FAIL" ]]; then
  timeout 10m opencode run -m "$MODEL_CHEAP" \
    "Summarize this nightly CI report in 5 bullet points, most urgent first, for a solo dev reading it on a phone: $(tail -c 6000 "$R")" \
    >> "$R" 2>/dev/null || true
fi

say ""
say "verdict: $status"
date +%s > "$AP_DIR/.nightly-last"
# Desktop notification if available (ignore failures in headless contexts)
command -v notify-send >/dev/null && notify-send "GeoWake nightly: $status" "$(basename "$R")" || true
exit 0
