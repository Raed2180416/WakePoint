#!/usr/bin/env bash
# Install GeoWake autopilot systemd --user units (worker, nightly, watchdog).
# Run once: bash autopilot/systemd/install.sh
set -euo pipefail
AP="$(cd "$(dirname "$0")/.." && pwd)"
UNIT_DIR="$HOME/.config/systemd/user"
mkdir -p "$UNIT_DIR"

unit() { # $1 name, $2 exec, $3 oncalendar, $4 description
  cat > "$UNIT_DIR/geowake-$1.service" <<EOF
[Unit]
Description=$4
[Service]
Type=oneshot
ExecStart=/usr/bin/env bash $AP/bin/$2
Nice=15
IOSchedulingClass=idle
EOF
  cat > "$UNIT_DIR/geowake-$1.timer" <<EOF
[Unit]
Description=Timer: $4
[Timer]
OnCalendar=$3
Persistent=true
RandomizedDelaySec=120
[Install]
WantedBy=timers.target
EOF
}

unit worker   worker.sh   "*:00/30"     "GeoWake autopilot worker (queue → CLI agent)"
unit nightly  nightly.sh  "02:30"       "GeoWake autopilot nightly quality gate"
unit watchdog watchdog.sh "*:05/10"     "GeoWake autopilot watchdog (kill stuck CLIs)"

chmod +x "$AP"/bin/*.sh
systemctl --user daemon-reload
for t in worker nightly watchdog; do systemctl --user enable --now "geowake-$t.timer"; done
# Keep user units running when logged out:
loginctl enable-linger "$USER" 2>/dev/null || echo "NOTE: run 'sudo loginctl enable-linger $USER' so timers run while logged out"
systemctl --user list-timers 'geowake-*' --no-pager
echo "Installed. Queue a task: cp autopilot/queue/TEMPLATE.md autopilot/queue/pending/\$(date +%F)-my-task.md && edit it"
