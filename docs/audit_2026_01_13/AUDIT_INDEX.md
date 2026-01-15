# WakePoint Audit (2026-01-13) — Index

## Executive summary (evidence-first)

**What’s solid (proven)**
- Alarm triggering pipeline exists and is explicitly split between background evaluation and foreground alarm presentation:
	- Background evaluates and emits `triggerAlarm` via `flutter_background_service`
	- Foreground receives `triggerAlarm` and calls `NotificationService.showWakeUpAlarm(...)`
- Notification actions have a cross-isolate persistence mechanism (file flags + SharedPreferences fallback) designed for reliability.
- “Wake Me” flow persists a full `TrackingSnapshot` (including directions payload) before starting the background service.
- Tracking persistence schema (`TrackingStateStore`) is fully enumerated (keys + types), including transit-leg persistence per route key.
- Offline coordinator exists and fails safe (offline + no cache ⇒ no route).
- Foreground-kill detection via heartbeat timeout exists (sets paused flag + shows “tracking paused” notification).
- Automated test suite executes successfully (`flutter test --disable-dds`: **All tests passed**, output indicates `+452` tests), including alarm evaluation and tracking/reroute simulations.

**What’s risky (supported but incomplete)**
- Process-death recovery and “alarm still triggers after OS kill” are not yet proven by code + runtime evidence.
- Alarm action consumption uses tight polling (200ms) which may be battery-costly if not strictly bounded.
- “Offline mode” usefulness is constrained by cache TTL (5 minutes) and origin-drift eviction (300m), so offline beyond short windows will often fail.

**What’s broken / likely broken**
- Alarm notification channel ID mismatch between Kotlin and Dart (risk: channel settings not applied as intended).
- Server proxy token issuance is bundleId-only (STOP_SHIP).

## STOP_SHIP (production blockers)

> Rule: Every item here must also exist as a Finding in a category file **and** have a row in CERTAINTY_MATRIX.md.

- **Server proxy can be abused to burn Maps API quota** (weak token issuance + permissive CORS defaults)
	- Evidence and fix: see `SECURITY_PRIVACY.md` and `CERTAINTY_MATRIX.md` rows for server-proxy auth.

## Next 10 actions (highest ROI, minimal ambiguity)

1. ✅ Complete entrypoint map with `SplashScreen` restore gate and native MainActivity channel/channel creation.
2. ✅ Enumerate `TrackingStateStore` schema (keys/types) and document restore semantics.
3. Run a device evidence matrix for Android 13/14:
	- screen off + lockscreen alarm delivery
	- swipe away foreground (heartbeat pause) + resume
	- process kill + relaunch restore/cleanup
	- DND/battery saver behaviors
4. Audit Android background execution constraints (foreground service notification, exact alarms, battery optimizations) vs current implementation.
5. Fix STOP_SHIP: harden geowake-server auth (attestation/per-install secret), lock down CORS defaults, and add abuse-resistant rate limits.
6. Remove the hardcoded Google Maps API key fallback behavior from Android build config.
7. Unify alarm notification channel IDs across Kotlin + Dart.
8. Make snapshot persistence size-bounded + verifiable; ensure start flow doesn’t silently start a non-restorable session.
9. Back off/gate the 200ms alarm-action poll timer and re-measure battery impact.
10. ✅ Fill completeness scoring weights and EKF readiness decision (now in `COMPLETENESS_AND_NEXT_PHASE_READINESS.md`).

## Audit files

- [ENTRYPOINTS_AND_LIFECYCLE.md](ENTRYPOINTS_AND_LIFECYCLE.md)
- [CRITICAL_USER_FLOWS.md](CRITICAL_USER_FLOWS.md)
- [STATE_AND_PERSISTENCE.md](STATE_AND_PERSISTENCE.md)
- [ALARM_DELIVERY_RELIABILITY.md](ALARM_DELIVERY_RELIABILITY.md)
- [PERFORMANCE_BOTTLENECKS.md](PERFORMANCE_BOTTLENECKS.md)
- [EDGE_CASES_AND_LOGICAL_GAPS.md](EDGE_CASES_AND_LOGICAL_GAPS.md)
- [SECURITY_PRIVACY.md](SECURITY_PRIVACY.md)
- [TEST_COVERAGE_AND_GAPS.md](TEST_COVERAGE_AND_GAPS.md)
- [PRIORITIZED_FIX_PLAN.md](PRIORITIZED_FIX_PLAN.md)
- [CERTAINTY_MATRIX.md](CERTAINTY_MATRIX.md)
- [COMPLETENESS_AND_NEXT_PHASE_READINESS.md](COMPLETENESS_AND_NEXT_PHASE_READINESS.md)

## Methodology log (what I actually did)

- 2026-01-13: Initialized audit folder + templates.
- 2026-01-12: Ran `flutter test --disable-dds` (All tests passed; output indicates `+452` tests).
