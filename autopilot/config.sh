# GeoWake Autopilot — shared config (sourced by all bin/ scripts)
# Everything here is overridable via environment.

REPO_ROOT="${AUTOPILOT_REPO:-$HOME/Projects/WakePoint}"
AP_DIR="$REPO_ROOT/autopilot"
QUEUE_DIR="$AP_DIR/queue"
LOG_DIR="$AP_DIR/logs"
REPORT_DIR="$AP_DIR/reports"
LOCK_FILE="$AP_DIR/.worker.lock"
HEARTBEAT_FILE="$AP_DIR/.heartbeat"

# Flutter SDK (not on non-interactive PATH by default)
export PATH="$HOME/flutter/bin:$PATH"

# ── Model ladder (free tiers, verified working headless 2026-07-24) ──────────
# Primary coding model, fallback, and cheap-triage model. The worker walks the
# ladder on non-zero exit. crush is the last resort (qwen3-coder via its own
# provider config).
MODEL_HEAVY="${AP_MODEL_HEAVY:-opencode/nemotron-3-ultra-free}"
MODEL_CODE="${AP_MODEL_CODE:-opencode/big-pickle}"
MODEL_CHEAP="${AP_MODEL_CHEAP:-opencode/deepseek-v4-flash-free}"

# Hard wall-clock cap per CLI invocation (minutes). Tasks may lower, never raise.
MAX_TASK_MINUTES="${AP_MAX_TASK_MINUTES:-45}"

# Watchdog: kill any opencode/crush process older than this (minutes).
WATCHDOG_KILL_MINUTES="${AP_WATCHDOG_KILL_MINUTES:-75}"

# ── Invariant-protected paths ────────────────────────────────────────────────
# The worker HARD-REVERTS any autopilot change that touches these and flags the
# task for human review. Mirrors AGENTS.md invariants.
INVARIANT_PATHS=(
  "lib/services/monetization/premium_service.dart"
  "lib/services/data_asset/mobility_consent_service.dart"
  "test/ekf/replay_harness_test.dart"
  "test/reachability/"
  "lib/core/reachability/"
  ".github/workflows/ci.yml"
)

# Grep patterns that must never be weakened by an autopilot diff.
INVARIANT_PATTERNS=(
  "canUseCoreAlarm"
  "canUseBackstopAlarm"
  "canUseBasicReliability"
  "canUseSingleActiveRoute"
)

# Preamble injected before every delegated prompt.
GUARDRAIL_PREAMBLE='You are an autonomous maintenance agent for GeoWake (Flutter transit wake-up alarm, repo at '"$REPO_ROOT"').
HARD RULES — violating any of these makes your work worthless:
1. Core alarm stays free: never gate canUseCoreAlarm / canUseBackstopAlarm / canUseBasicReliability / canUseSingleActiveRoute behind Pro.
2. Never touch: lib/services/monetization/premium_service.dart, lib/services/data_asset/mobility_consent_service.dart, test/ekf/replay_harness_test.dart, test/reachability/, lib/core/reachability/, .github/workflows/ci.yml. If your task seems to require it, STOP and explain instead.
3. No snooze features. Never delay or suppress a wake alarm.
4. User-facing app name is "GeoWake" — never "WakePoint" or "geowake2".
5. Never delete tests, never add skip:/tags to dodge failures.
6. Keep diffs minimal and focused on the task. Match surrounding code style.
7. When done, run: export PATH="$HOME/flutter/bin:$PATH" && flutter analyze lib/ --no-fatal-infos — and fix any NEW errors you introduced.
TASK:'
