# Business OS — Engineering Autopilot

Goal: the codebase improves, stays green, and reacts to the outside world
(crashes, reviews, dependency breakage, policy changes) 24/7 at $0/month,
with humans only reviewing and merging.

Working v1 ships in this repo at `autopilot/` (worker + nightly + watchdog +
systemd timers). This doc is the operating manual and the growth path.

## 1. What runs today (v1, this machine)

- **Worker** (`autopilot/bin/worker.sh`, every 30 min): drains one task from
  `autopilot/queue/pending/`, delegates to free CLI agents with a model ladder
  (opencode Zen free models → crush/qwen3-coder), hard `timeout`, validates
  (invariant paths reverted, `flutter analyze`, task's `test_cmd` or the
  never-late harness), commits to `autopilot/<id>` branch for human review.
- **Nightly** (02:30): analyze + never-late + reachability + full 1373-test
  suite + server jest; writes `autopilot/reports/nightly-<date>.md`; files fix
  tasks automatically for red gates.
- **Watchdog** (every 10 min): kills CLI processes >75 min, clears stale
  locks, requeues orphaned tasks, alarms if nightly silent >48h.
- Verified on 2026-07-24: opencode headless round-trip ~6.5s
  (`opencode/big-pickle`), crush ~11s. Machine: Ryzen 7840HS / 16 threads /
  14GB RAM / RTX 4060 8GB — free cloud models are the primary brain; a local
  Qwen-coder ~7B under llama.cpp on the 4060 is the offline fallback only.

## 2. Task sources (what feeds the queue)

| Source | Mechanism | Status |
|---|---|---|
| Nightly red gates | auto-filed by `nightly.sh` | live |
| You | drop a file from `queue/TEMPLATE.md` | live |
| L2 (Claude) sessions | leave scoped follow-ups in queue instead of doing everything in-session | live (convention) |
| Scheduled Claude runs | weekly cron session (schedule skill) reviews reports + failed queue; fact-check note: the June-2026 "headless billed separately" change was announced then PAUSED — headless still draws from subscription today, but don't build anything that breaks if that reverses | available |
| Play Store reviews | post-launch: reviews API/RSS → classify (bug/feature/rant) with `MODEL_CHEAP` → bug reviews become tasks with device/model context | build at launch |
| Crash reports | Sentry free tier (5k events/mo) → daily digest → new crash signatures become tasks | build at launch |
| Dependency alerts | Dependabot PRs on GitHub → nightly notices broken CI → task | enable with repo push |
| Policy watch | monthly L2 session re-checks Play policy pages (dated checklist in 01) | cadence |

## 3. Division of labor (what to delegate where)

- **Free models (L1) are good at:** single-file scoped fixes with a failing
  test to satisfy, mechanical refactors, dead-code removal, doc/store-copy
  drafts, log triage, summarization. Always give them: one goal, the exact
  test command, and file paths.
- **Never give L1:** reachability/EKF logic, monetization gates, consent,
  manifest/permissions, CI config, multi-file architectural changes. These are
  L2 (Claude session) work by policy (`07_governance.md`).
- **Prompt shape that works:** goal + constraint + verification command.
  The worker injects invariants automatically (`GUARDRAIL_PREAMBLE`).

## 4. Growth path

1. **Now:** systemd timers on this machine (`bash autopilot/systemd/install.sh`).
2. **At launch:** add review-scraper + Sentry digest task sources; push repo to
   GitHub private, enable existing CI (never-late gate already enforced there),
   Dependabot, gitleaks/semgrep job (fix in flight).
3. **Oracle VM (free ARM, configs already in `deploy/oracle-vm/`):** move the
   backend + GraphHopper there; the VM ALSO runs a clone of this autopilot
   (worker+nightly) so automation survives your laptop being off; queue syncs
   via the git repo (`autopilot/queue/` is committed).
4. **Scale-up:** if/when revenue funds a workstation, the same scripts point at
   bigger local models (`AP_MODEL_*` env) — architecture unchanged.

## 5. Staying current (docs, bugs, ecosystem)

- Nightly `flutter --version` + `dart pub outdated --no-dev-dependencies`
  snapshot lands in the report (add to nightly when convenient).
- Monthly L2 session: refresh AUTOMATION_BLUEPRINT facts (model lists, free
  tiers, tool versions) — treat every >30-day-old "verified" claim as stale.
- context7 MCP (already configured for Claude sessions) for current library
  docs during L2 work; L1 agents get doc excerpts pasted into their task file.
