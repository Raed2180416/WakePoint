# Business OS — Governance & Safety Rails

The autonomy system is allowed to do a lot. This file defines what it may
NEVER do without a human, how work escalates between intelligence tiers, and
the invariants that survive every future decision. Every agent prompt at every
tier must carry a pointer to this file and to `AGENTS.md`.

## 1. The four intelligence tiers

| Tier | Who | Cost | Runs | Allowed to |
|---|---|---|---|---|
| L0 deterministic | cron/systemd, GitHub Actions, shell scripts | $0 | 24/7 | run gates, collect metrics, file tasks, alert. No judgment calls. |
| L1 free workers | opencode (Zen free models), crush (qwen3-coder) via `autopilot/` | $0 | 24/7 | small scoped diffs on `autopilot/*` branches; drafts (store copy, replies); triage/summarize. |
| L2 architect | Claude Code sessions (like this one), scheduled or manual | metered | bursts | multi-file engineering, refactors, releases prep, strategy synthesis, reviewing/merging L1 output. |
| L3 human (Raed) | you | — | minutes/day | everything below. |

**Escalation:** L0 red gate → files L1 task. L1 fails twice or task touches a
protected area → lands in `autopilot/queue/failed/` → L2 session picks it up.
L2 uncertain or the decision is on the L3-only list → asks you.

## 2. L3-only decisions (the system must never do these alone)

1. **Release anything** — Play Console uploads, rollout % changes, store
   listing edits go out only after you press the button.
2. **Money** — price changes, new SKUs, refunds, enabling billing, ad unit
   changes, any spend above ₹0.
3. **Public speech** — posts, replies to reviews/PR/social published under the
   brand. Agents DRAFT; you send. (Automation may post to your own private
   Telegram/Discord freely.)
4. **Privacy surface** — consent copy, privacy policy, data-egress activation
   (the `NullEgressSink` swap), retention changes, any new PII collection.
5. **The invariants in §3** — no tier may change them, including L2.
6. **Account/credential actions** — creating accounts, rotating keys, granting
   OAuth. Agents prepare exact instructions; you execute.

## 3. Product invariants (constitutional — change requires you, in writing)

1. Core alarm is free forever (`canUseCoreAlarm`, `canUseBasicReliability`,
   `canUseBackstopAlarm`, `canUseSingleActiveRoute` never gated).
2. Never-late guarantee: `test/ekf/replay_harness_test.dart` +
   `test/reachability/` are hard CI gates; no skip/tags/deletion, ever.
3. Consent default-OFF; zero egress without explicit opt-in.
4. Pro-feature failure can never degrade the core alarm (fail-open).
5. No snooze on wake alarms.
6. User-facing name is GeoWake.

Enforcement is layered: `.semgrep.yml` rules + `autopilot/config.sh`
INVARIANT_PATHS hard-revert + CI never-late gate + human review of every
`autopilot/*` branch.

## 4. Risk register (what could hurt us and the standing answer)

| Risk | Standing control |
|---|---|
| Agent ships a bad fix | L1 output quarantined on branches; analyze + never-late gate must pass before a branch is even offered; you merge. |
| Runaway API spend (Google Maps) | Server-side global daily quota kill-switch (see 05); budget alerts; key restricted to Android app SHA-1. |
| Quota drained by attacker | Per-IP + per-token caps, Play Integrity attestation post-launch, kill-switch as backstop. |
| Free-model providers vanish/change | Model ladder is config (`AP_MODEL_*`); crush is second vendor; nightly gates catch silent degradation. |
| Stuck/hung agents (CLIs, workflows) | `watchdog.sh` kills >75-min processes, requeues orphans, 48h heartbeat alarm. |
| Play policy strike | Launch checklist (01) tracks policy-sensitive surfaces; any manifest/permission diff is L2+L3 review by definition (CI config protected). |
| Privacy/legal (DPDP) | Privacy surface is L3-only; consent copy fixes are launch-blocking; telemetry stays inert-by-default. |
| Google ships "wake me at my stop" | Moat strategy in 03: be deeper (underground reliability, safety features); speed to 100K users. |
| Burnout / bus factor | Everything here is written down; any capable agent (or human) can re-derive operations from docs/business_os + AGENTS.md + autopilot/README. |

## 5. Cadence

- **Every 30 min:** L1 worker drains one queue task.
- **Every 10 min:** watchdog.
- **Nightly 02:30:** full gates + report + auto-filed fix tasks.
- **Weekly (you, ~30 min):** review `autopilot/reports/`, merge/deny branches,
  skim nightly verdicts, approve queued releases/posts.
- **Monthly (L2 session):** deep audit + strategy review against 00_DECK KPIs;
  refresh stale research (model list, policy changes, competitor moves).
