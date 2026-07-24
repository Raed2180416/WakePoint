#!/usr/bin/env bash
# GeoWake Autopilot watchdog — the "workflows must never get stuck waiting on a
# CLI" guarantee. Kills runaway opencode/crush processes, clears stale locks,
# requeues orphaned tasks, and alerts when heartbeats go silent.
set -uo pipefail
source "$(dirname "$0")/../config.sh"

now=$(date +%s)
max_secs=$(( WATCHDOG_KILL_MINUTES * 60 ))

# 1. Kill CLI agent processes that have run too long.
for name in opencode crush; do
  while read -r pid etimes; do
    [[ -z "${pid:-}" ]] && continue
    if (( etimes > max_secs )); then
      echo "$(date -Is) killing stuck $name pid=$pid age=${etimes}s" >> "$LOG_DIR/watchdog.log"
      kill -TERM "$pid" 2>/dev/null; sleep 5; kill -KILL "$pid" 2>/dev/null || true
    fi
  done < <(ps -o pid=,etimes=,comm= -C "$name" 2>/dev/null | awk '{print $1, $2}')
done

# 2. Clear stale worker lock (holder dead).
if [[ -f "$LOCK_FILE" ]]; then
  holder=$(cat "$LOCK_FILE" 2>/dev/null || true)
  if [[ -n "$holder" ]] && ! kill -0 "$holder" 2>/dev/null; then
    if ! flock -n "$LOCK_FILE" -c true 2>/dev/null; then :; else
      echo "$(date -Is) cleared stale lock (pid $holder dead)" >> "$LOG_DIR/watchdog.log"
      rm -f "$LOCK_FILE"
    fi
  fi
fi

# 3. Requeue tasks orphaned in running/ for > 2h (worker died mid-task).
find "$QUEUE_DIR/running" -type f -mmin +120 2>/dev/null | while read -r f; do
  echo "$(date -Is) requeueing orphaned task $(basename "$f")" >> "$LOG_DIR/watchdog.log"
  mv "$f" "$QUEUE_DIR/pending/"
done

# 4. Heartbeat alarm: nightly hasn't run in 48h → something is broken.
if [[ -f "$AP_DIR/.nightly-last" ]]; then
  last=$(cat "$AP_DIR/.nightly-last")
  if (( now - last > 172800 )); then
    echo "$(date -Is) ALERT: nightly has not completed in >48h" >> "$LOG_DIR/watchdog.log"
    command -v notify-send >/dev/null && notify-send -u critical "GeoWake autopilot" "Nightly hasn't run in >48h — check systemd timers" || true
  fi
fi
exit 0
