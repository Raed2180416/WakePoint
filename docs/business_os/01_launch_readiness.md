# Business OS — Launch Readiness

Live go-live checklist. Derived from the 2026-07-24 production audit (36 verified
findings, 8 P0) + Play policy research (`research/play_policy_2026.md`). Status
reflects work done this session.

## 1. Ship-blockers (P0) — status

| # | Blocker | Status |
|---|---|---|
| 1 | SNOOZE on core alarm violated no-snooze + had no OS backstop | ✅ fixed (commit e7b5b64) |
| 2 | Process-death backstop chimed once (not insistent); no cold-start alarm resume | ✅ fixed |
| 3 | Anti-theft (Pro) alarm could override the core destination alarm | ✅ fixed (invariant #4, unit-tested) |
| 4 | startTracking armed UI even when background isolate never ACKed | ✅ fixed (escalate + telemetry) |
| 5 | Release build silently fell back to debug signing | ✅ fixed (hard-fail for .aab / -PgeowakeRelease) |
| 6 | In-app privacy policy URL was a dead domain; no policy hosted | ⚠️ app wired to Railway /legal/*; **routes + real policy content must go live** |
| 7 | Server: anyone could mint a JWT and drain the Google Maps budget | ✅ fixed (kill-switch + per-family quota + per-jti caps; 55/55 jest; commit 3746a0b) |
| 8 | Uncommitted diff referenced untracked impl files (broken clone) | ✅ fixed (commit 16f06ce) |

**7 of 8 P0s closed in code.** #6 (privacy policy) is code-complete — the app
links live `/legal/*` routes on the backend; the only remaining step is
deploying the backend so those URLs resolve publicly, plus your review of the
policy copy (contact + effective date are env-overridable).

## 2. Play compliance (must be true before submission)

- [x] Drop `USE_EXACT_ALARM`, keep `SCHEDULE_EXACT_ALARM` only (done).
- [x] Prominent background-location disclosure meets Play's bar (done).
- [x] Background location grantable on Android 11+ via Settings fallback (done).
- [ ] **Bump `targetSdkVersion` 35 → 36** before Aug 31 2026 (compileSdk already
      36). Regression-test Android 16 behavior changes first.
- [ ] **Real AdMob app ID + unit IDs** wired via build config (test IDs ship
      zero revenue — user must create AdMob account).
- [ ] **Create the 4 prepaid pass SKUs in Play Console** as *consumable* in-app
      products (not subscriptions): `geowake_pro_daily` ₹7, `geowake_pro_weekly`
      ₹35, `geowake_pro_monthly` ₹99, `geowake_pro_yearly` ₹899. The ladder
      paywall + entitlement logic are built and tested; they just need the SKUs
      to exist. (Optional: keep the legacy `geowake_pro_onetime` for restores.)
- [ ] **Privacy policy live** at the wired URL, matching the app's real data
      behavior (location, Guardian share, ads SDK; mobility pipeline is inert).
- [ ] Play Console: Permissions Declaration Form (background location, single
      named feature + ≤30s video), Foreground Service declarations (location +
      mediaPlayback), Data Safety form matching the policy exactly.
- [ ] Full-screen-intent revocation fallback path present (settings deep link +
      heads-up fallback) — verify.
- [ ] If the Play developer account post-dates Nov 13 2023: **12 testers × 14
      consecutive days** closed test before production. Budget 3–4 weeks total.
- [ ] $25 one-time Play Console fee paid.

## 3. Follow-ups (P1/P2 + critic findings) — autopilot/next-session

Filed as work items (not launch-blocking, but track):
- **Refund/entitlement revocation** (P1): a Play refund never revokes Pro —
  add restore-on-foreground diff + (robust) server RTDN webhook. *(monetization
  agent addressing the client-side restore path this session.)*
- **No remote crash reporting** (P1): wire Sentry free tier (5k events/mo) so a
  release crash-loop isn't invisible.
- **Localization unused** (P1, critic): 5 `.arb` files exist (en/hi/ta/te/bn),
  every screen hardcodes English. India-first reach wants this — but it's a
  large every-screen sweep; do as an autopilot campaign, not a blocker.
- **iOS unbuildable** (P2, critic): `ios/` has no Podfile. Fine — launch is
  Android-only; note for any future iOS plan.
- **Server jest suite unenforced in CI** (P1): add the server-tests job *(server
  agent adding this session).*
- Cache key-count bound; Places session-token end; egress URL default-empty;
  RouteSessionManager aux-map eviction; dead RouteMetadata removal — *(agents
  this session.)*
- docs/PRIVACY.md accuracy (omits 2 default data flows; stale k-anon threshold)
  — reconcile with the hosted policy before submission.

## 4. Quality gates that must stay green (CI-enforced)

`flutter analyze lib/` (0 errors), never-late replay harness, reachability
suite, scale test, full 1373-test suite, + new: server jest, gitleaks, semgrep
invariant rules. Baseline this session: analyze clean, 1373/1373 pass.

## 5. The one-line go/no-go

Go when: all P0 closed, Play forms submitted with matching privacy policy live,
real AdMob IDs in, targetSdk 36, and the never-late gate + successful-wake
behavior verified on a real Indian-OEM device (the battery-killer cohort is the
only thing that can silently break the core promise).
