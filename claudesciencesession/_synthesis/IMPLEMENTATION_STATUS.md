# WakePoint Android Reliability — Implementation Status

Branch: `android-reliability-hardening` (off `stable-release-1`). Baseline before work: `flutter analyze` 207 info / 0 errors; test suite +551 / -22.

## Landed & verified in the repo

### Fire-decision cluster — DONE (analyze 0 err; +9 new proof tests; fixed ~3 baseline)
- **G10** alarm now evaluates *during a GPS blackout* — driven from the existing periodic tick using dead-reckoned EKF state, without re-snapping stale GPS. `location_stream_handler.dart`, `trackingservice.dart`.
- **G11** ETA speed uses `EKF.v` in metro/degraded/blackout (was GPS-speed which collapses in a tunnel). `alarm_controller.dart`.
- **G12** critical-fractile firing: fire at `median − k·σ` (never the median). `alarm_evaluator.dart`, `alarm_controller.dart`, new `lib/config/fire_decision_config.dart`.
- **G13** metro stop-count inflated by `k·σ_s` (counts a stop early = safe).
- **G27** GPS-accuracy gate (drops coarse/"approximate" ~1–3 km fixes). **G28** location-service-status watchdog. `location_manager.dart`.
- **G26** removed per-tick `mumbai_alarm_debug.txt` file-write (battery/latency + it crashed headless tests → fixed ~11 pre-existing metro test failures).

### Route/journey cluster — DONE (analyze 0 err; +9 new proof tests incl. a real wrong-direction integration test)
- **G14/G15** signed along-route wrong-direction / wrong-train detection → `WrongDirectionAlert` (works on metro legs; replaced the `_headingAgreement` stub that returned 0.5). `active_route_manager.dart`, `route_session_manager.dart`.
- **G16** OSM-vs-Google stop-count cross-check (20% tolerance) — fixes silent "N stops before" undercount. `transfer_utils.dart`.
- **G17** route versioning/expiry stamping + stale eviction. `route_cache.dart`, `direction_service.dart`.
- **G18** 24h sanity ceiling that does NOT refuse the flagship 6–10h sleeper. `homescreen.dart`.

### Native survival/delivery + 2026 compat — DONE (`flutter build apk --debug` SUCCEEDS; analyze 0 err)
- **G1** `PARTIAL_WAKE_LOCK` held for the ride via a new in-repo `wakepoint_native` Flutter plugin (Kotlin) + zero-batching game-rate IMU. (Fixes the "IMU doesn't stream screen-off" showstopper.)
- **G2** battery-optimization exemption + per-OEM autostart deep-links (`oem_autostart_service.dart`) wired into `permission_service.dart`.
- **G4** `autoStartOnBoot: true`. **G5** `AlarmManager.setAlarmClock` ETA backstop (Doze-proof, re-armed from `notification_updater.dart`, cancels on fire) — the universal reliability anchor. **G6/G7** self-contained background-isolate alarm (sound + notification + FSI-capability guard), no longer delegated to a possibly-dead UI isolate.
- **Compat**: `targetSdk 34→35`, `minSdk→24`, deleted dead duplicate `.kts` build files, manifest perms (`WAKE_LOCK`, `USE_EXACT_ALARM`, `SCHEDULE_EXACT_ALARM`, `RECEIVE_BOOT_COMPLETED`) + OEM `<queries>`. Also fixed two pre-existing build blockers (broken NDK stub; `google_fonts` 6→8 incompatibility) so the repo builds at all.

### EKF-honesty cluster — A1 + G21 DONE (112 EKF + sensor_fusion tests green; analyze 0 err)
- **G20/A1** ZUPT tightens VELOCITY only (was fabricating position certainty → wrong snaps); `maxSigmaS 200→3000` so σs grows HONESTLY through a blackout (the Majestic-Cubbon 388s test now shows σs→~3000m vs the old dishonest 250m → honest critical-fractile margin). Corrected 2 stale tests that asserted the old cap.
- **Empirical finding:** A1 does NOT regress station snaps — the existing `DEGRADED_NEAREST` association fallback absorbs wide-σ, so **A3 (dwell-count) is unnecessary** (refutes the spec's warning).
- **G21** no-gyroscope detection (`sensor_fusion.dart`) → honest wider σs floor (`ekf_pipeline.dart`, `ekf_orchestrator.dart`). Default-off; only activates on real gyro-less hardware.
- **A4 (learned velocity): deliberately NOT shipped** — audit confirmed it is circular (collapses on real data, r=−0.33). Underground anchoring stays on stop/ZUPT detection.

## Deferred / follow-up (with reasons)
- **A2 motion-gated ZUPT** — refinement; the smooth-cruise spurious-ZUPT stall doesn't reproduce in the passing tunnel tests. Add if a real ride shows an underground stall.
- **Device-only verification** (write correct here, prove on a phone): real OEM-kill survival, alarm audio on a locked screen, `setAlarmClock` firing in Doze after force-kill, per-ROM OEM autostart `ComponentName`s, background IMU delivery rate.
- **iOS**: honest un-closable for the current architecture (no background raw-IMU / long-lived location FGS). Scope as fast-follow.

See `WAKEPOINT_MASTER_GAP_REGISTER.md` and `ANDROID_COMPATIBILITY_AND_DEVICE_REQUIREMENTS.md`.

## Final-pass additions
- **alarmMode production bug (root cause of all 10 remaining alarm-test failures):** `TrackingService.startTracking` built the session `params` map with `alarmValue` but NOT `alarmMode`, so `_alarmMode` was always null → **stops and time alarm modes silently never ran in production**. One-line fix `trackingservice.dart:250` (`'alarmMode': alarmMode`). All 10 pass, +44/-0.
- **Fractile-σ clamp (A1×G12/G13 interaction):** honest σ (→3km) is now clamped to `maxFractileSigmaMeters=300` *for the fire decision only* (not the filter's reported σ), so a long fully-underground blackout fires ~1-2 stops early at most (safe AND tight) instead of many stops early. `alarm_evaluator.dart` (cushion + etaSigmaSeconds), `alarm_controller.dart` (_etaSigmaSeconds), `fire_decision_config.dart`.

## Round 2 — core-product / sim / metro / GPS-out (in progress)
- **E1 (THE north-star fix) — DONE & verified:** GPS-out dead-reckoning now actually ACTIVATES in production. `onGpsUnavailable` was still only called from the test path, so the EKF orchestrator never entered degraded mode on a real tunnel GPS loss (it dead-reckoned in the wrong mode). Wired into `sensor_fusion.dart`: track last-GPS-fix time; when GPS is silent > 3 s, call `ekf.onGpsUnavailable()` before feeding IMU → proper degraded DR (honest σ growth). analyze 0-err; 112 EKF+sensor tests green.
- **4 deep workflows completed** (findings persisted in `_synthesis/*_findings.json`):
  - *Metro wrong-snap root cause:* stop list built by nearest-any-station-within-500m across ALL lines; the `line`/`city` fields that would disambiguate are discarded. Fix = line-filter (agent implementing).
  - *Sim engine:* fake linear-interp panel is dead code loading a missing asset; real EKF only wired to one 49MB log; UI locked to that log; no alarm-in-sim; no error metric; non-deterministic. Rebuild in progress (agent).
  - *Completeness:* GPS-out state invisible to rider; wrong-direction alert built but dangling (no consumer); no alarm preview / test-alarm / snooze; cold-start-underground engine-dead; brand split GeoWake vs WakePoint. (agent implementing top items.)
- **Claude-Science GPS-out handoff — WRITTEN** (`CLAUDE_SCIENCE_HANDOFF_GPS_OUT.md`): P1 real velocity, P2 dwell-anchor, P3 second anchor (curvature/barometer/RF), P4 cold-start-underground, P5 ZUPT-veto calibration, P6 honest guarantee — + the data-collection campaign.

## Round 2 — VERIFIED COMPLETE (core-completeness / sim / metro / GPS-out)
**Combined verification:** `flutter analyze lib/` = 0 errors · full suite **+602 / 0 real failures** (1 flaky perf benchmark passes in isolation at 16,183 samples/s ≈ 160× real-time) · **`flutter build apk` SUCCEEDS** · **`flutter build web` (sim dashboard) SUCCEEDS**.

- **GPS-out innovation (E1):** now activates in production — GPS silence >3s → EKF degraded DR (was test-path only). `sensor_fusion.dart`. Verified (112 EKF tests green).
- **Metro wrong-snap + ordering:** (1) line-filter fix — a route only gets its OWN line's stops (+3 tests); (2) **ordered per-line sequences generated** from the existing OSM+scrape coords (`scripts/build_line_sequences.py` → 37 confident lines / 19 cities / 585 stops); (3) **wired into `transfer_utils`** line-first (hardcoded ordered sequence sliced to the leg, arc-ordered) with safe fallback; (4) **pan-India verified** — code-level ordered-slice sweep passes for 8 cities (Bengaluru/Delhi/Mumbai/Kolkata/Chennai/Hyderabad/Kochi/Pune) + data-level 32/37 clean. 9 branched/ring/blank-tag lines quarantined (fall back to line-filter) + diagnosed for a GTFS pass. Data packaged for Claude-Science (`assets/india_metro/metro_dataset.json` + `METRO_DATA_FOR_CLAUDE_SCIENCE.md`).
- **Simulation engine:** dead fake linear-interp panel deleted; real EkfOrchestrator wired into ALL scenarios; ground-truth error/RMSE/max-drift metrics; real alarm fires in-sim with lead-error; scenario/GPS-dropout picker restored; deterministic playback; leak + FINISHED-state fixed. Compiles for web. (Visual/runtime pass needs a human in Chrome.)
- **Core completeness (trust):** wrong-direction alert wired to a notification (was dangling); GPS-out state surfaced to the rider ("No GPS — estimating from motion"); pre-sleep alarm preview; "test my alarm" button; post-arrival + snooze/re-alert. (27 tests.)
- **Claude-Science GPS-out handoff written** (`CLAUDE_SCIENCE_HANDOFF_GPS_OUT.md`) + metro data handoff.
- **Cold-start-underground:** SAFE via the exact-alarm ETA backstop (fires at planned arrival, GPS-independent). The DR-*localization* seed is research-gated (P4) — not shipped (would risk late-firing without the underground anchor).

### Genuinely open (honest reasons)
- Sim visual/runtime behavior — compiles clean; needs a human Chrome pass.
- Onboarding flow (L) — partially covered by the reliability-setup step; full flow not built.
- 9 flagged metro lines — need official GTFS (per-user, leave code as-is; fall back is safe).
- App name kept **GeoWake** (per user). Display label `geowake2` could read "GeoWake" — minor, deferred.
- GPS-out research P1–P6 — genuinely needs real multi-device rides (handed to Claude-Science).
