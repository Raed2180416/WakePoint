# GeoWake Autopilot

Round-the-clock maintenance loop that runs **on this machine at $0/month**, built
around free-tier CLI agents (opencode Zen free models + crush/qwen3-coder), with
hard guardrails so it can never damage the product while you sleep.

```
┌────────────┐   files    ┌────────────┐  timeout+ladder  ┌──────────────────┐
│ queue/     │──────────▶│ worker.sh   │─────────────────▶│ opencode / crush  │
│ pending/*.md│  every 30m │ (flock'd)  │◀─────────────────│ (free models)     │
└────────────┘            └─────┬──────┘     diff          └──────────────────┘
      ▲                         │ validate: invariants → analyze → tests
      │ auto-filed on red       ▼
┌─────┴──────┐            ┌────────────┐        ┌──────────────────────────┐
│ nightly.sh │  02:30     │ autopilot/ │        │ HUMAN REVIEW              │
│ full gates │───────────▶│ <id> branch│───────▶│ git diff main..autopilot/x│
└────────────┘            └────────────┘        │ merge or delete           │
      watchdog.sh every 10m: kills stuck CLIs,  └──────────────────────────┘
      clears stale locks, requeues orphans, heartbeat alarms
```

## Install

```bash
bash autopilot/systemd/install.sh          # enables 3 systemd --user timers
sudo loginctl enable-linger $USER          # keep timers alive when logged out
```

## Use

- **Queue a task:** copy `queue/TEMPLATE.md` to `queue/pending/<date>-<slug>.md`,
  edit. One focused task per file. Files are processed lowest-sort-order first.
- **Review output:** each completed task = one `autopilot/<id>` branch + entry in
  `reports/<date>.md`. `git diff <base>..autopilot/<id>`, merge or delete.
- **Nightly report:** `reports/nightly-<date>.md` — every gate (analyze,
  never-late harness, reachability, full suite, server jest), repo state, and
  auto-filed fix tasks for anything red.
- **Logs:** `logs/<task-id>.log` (full CLI transcript), `logs/watchdog.log`.

## Safety model (why it can't hurt you)

1. Worker refuses to start if the repo has human WIP in code paths.
2. Every CLI invocation runs under `timeout`; the watchdog kills anything older
   than 75 min regardless; orphaned tasks are requeued automatically.
3. Invariant paths (premium gates, consent, reachability, never-late test, CI
   config) are **hard-reverted** if touched; diffs that delete lines containing
   gate symbols are rejected.
4. A change only survives if `flutter analyze` passes AND the task's `test_cmd`
   (default: the never-late replay harness) passes.
5. Output lands on `autopilot/*` branches only — never main branches, never
   pushed, never released. You merge by hand.
6. Escalation path: anything the free models can't do lands in `queue/failed/`
   with a reason — feed those into a Claude Code session (the "architect" tier).

## Model ladder

Set in `config.sh`: task's own model → `MODEL_HEAVY` (nemotron-3-ultra-free) →
crush. Override per task via `model:` frontmatter, or globally via
`AP_MODEL_*` env vars. All free; rotate as OpenCode Zen's free list changes.
