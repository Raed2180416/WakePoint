# Completeness & Next-Phase (EKF) Readiness

## Scoring method

### Denominator definition (what “100% complete” means)

Define a checklist of core capabilities required for the core promise:

1) Onboarding + permissions UX (foreground/background location, notifications)
2) Route acquisition and validation (directions fetch/proxy, validation)
3) Tracking reliability (foreground + background)
4) Alarm evaluation correctness (time/distance/stops)
5) Alarm delivery (notification/audio/vibration, stop/snooze)
6) State persistence + restore after kill
7) Offline behavior (no network)
8) GPS degradation handling (stale, jitter, loss)
9) Deviation/reroute/termination policies
10) Battery/power policy correctness
11) Release-safety: debug/test modes isolated
12) Server proxy security and reliability (if used)

### Weights

Weights (sum = 100). Rationale: bias toward user-safety/reliability and security.

1) Onboarding + permissions UX: 8
2) Route acquisition + validation: 10
3) Tracking reliability (foreground + background): 15
4) Alarm evaluation correctness (distance/time/stops): 12
5) Alarm delivery (notif + sound/vibration + actions): 12
6) State persistence + restore after kill: 10
7) Offline behavior: 6
8) GPS degradation handling: 6
9) Deviation/reroute/termination: 6
10) Battery/power policy correctness: 5
11) Release-safety (debug/test isolation): 4
12) Server proxy security + reliability: 6

## Category-by-category completeness

For each category:
- **Weight**:
- **Completeness %**:
- **Confidence in %** (CERTAIN/HIGH/MEDIUM/LOW/UNKNOWN):
- **What’s done (evidence)**:
- **What’s missing**:
- **Risks**:
- **Gating criteria to raise completeness**:

Percentages reflect “implementation present + verified evidence” (code + tests/logs). Platform behaviors requiring real devices remain partial.

1) Onboarding + permissions UX
- **Weight**: 8
- **Completeness %**: 70%
- **Confidence in %**: HIGH
- **What’s done (evidence)**: Permission flow exists (`PermissionService.requestEssentialPermissions()`), used on Wake Me.
- **What’s missing**: Consolidated permission prompting across app; device confirmation for background location + notification permission UX on Android 13+.
- **Gating criteria**: single permission prompt path; device run confirming background location permission set to “all the time”.

2) Route acquisition and validation
- **Weight**: 10
- **Completeness %**: 75%
- **Confidence in %**: HIGH
- **What’s done (evidence)**: Offline-aware route fetch via `OfflineCoordinator`; multiple pre-start validations in HomeScreen.
- **What’s missing**: Clear error UX for offline/no-cache and robustness for longer offline durations.
- **Gating criteria**: device run in airplane mode; documented offline policy and tests.

3) Tracking reliability (foreground + background)
- **Weight**: 15
- **Completeness %**: 55%
- **Confidence in %**: MEDIUM
- **What’s done (evidence)**: Background service orchestration exists; ack+retry invoke; heartbeat-based “foreground gone” detection.
- **What’s missing**: Real-device evidence across screen-off, OEM restrictions, battery saver, and process-kill scenarios.
- **Gating criteria**: instrumented device run matrix for Android 13/14 with screen off + lockscreen + kill/restart.

4) Alarm evaluation correctness
- **Weight**: 12
- **Completeness %**: 70%
- **Confidence in %**: HIGH
- **What’s done (evidence)**: Core distance-mode logic covered by automated tests; alarm controller routes/time/stops logic exists.
- **What’s missing**: Device verification of time/stops/metro scenarios, especially under GPS noise.
- **Gating criteria**: targeted unit tests for time/stops + at least one real scenario capture.

5) Alarm delivery (notification/audio/vibration/actions)
- **Weight**: 12
- **Completeness %**: 60%
- **Confidence in %**: MEDIUM
- **What’s done (evidence)**: Full-screen alarm notification path; pending alarm re-post; action flags via file + prefs.
- **What’s missing**: Device evidence for lockscreen delivery, DND/battery-saver interactions, and action reliability when app is killed.
- **Gating criteria**: device runs validating alarm delivery + action consumption across states.

6) State persistence + restore after kill
- **Weight**: 10
- **Completeness %**: 65%
- **Confidence in %**: MEDIUM
- **What’s done (evidence)**: TrackingStateStore schema fully enumerated; restore gate refuses unsafe restore; snapshot minimization.
- **What’s missing**: Robust snapshot persistence (size-bounded/atomic) and device proof of restore behavior.
- **Gating criteria**: atomic snapshot format + device kill/relaunch test.

7) Offline behavior
- **Weight**: 6
- **Completeness %**: 45%
- **Confidence in %**: HIGH
- **What’s done (evidence)**: Offline path exists and fails safe when no cache.
- **What’s missing**: Offline usefulness beyond 5 minutes (TTL) and across origin drift.
- **Gating criteria**: explicit offline cache policy + UX; longer TTL or offline session mode.

8) GPS degradation handling
- **Weight**: 6
- **Completeness %**: 40%
- **Confidence in %**: MEDIUM
- **What’s done (evidence)**: Dropout detection exists; sensor fusion fallback present.
- **What’s missing**: EKF not implemented; runtime validation of dropout + jitter behavior.
- **Gating criteria**: define/measure error bounds; implement/validate EKF (future phase).

9) Deviation/reroute/termination policies
- **Weight**: 6
- **Completeness %**: 50%
- **Confidence in %**: MEDIUM
- **What’s done (evidence)**: Wiring exists; termination policy evaluated and can terminate with message.
- **What’s missing**: Proof that reroute decisions are emitted reliably; device validation to prevent false terminations.
- **Gating criteria**: device scenarios for moderate/extreme deviation; logs showing correct decisions.

10) Battery/power policy correctness
- **Weight**: 5
- **Completeness %**: 40%
- **Confidence in %**: LOW
- **What’s done (evidence)**: Timers identified; some power-policy config exists.
- **What’s missing**: Measured battery impact and tightened scheduling.
- **Gating criteria**: profiling session + reductions (poll backoff, heartbeat interval).

11) Release-safety: debug/test modes isolated
- **Weight**: 4
- **Completeness %**: 30%
- **Confidence in %**: LOW
- **What’s done (evidence)**: Some `isTestMode` flags exist.
- **What’s missing**: Full audit proving test/relay/debug paths cannot activate in production.
- **Gating criteria**: build-time guards + config audit.

12) Server proxy security and reliability
- **Weight**: 6
- **Completeness %**: 10%
- **Confidence in %**: CERTAIN
- **What’s done (evidence)**: Server exists, rate limit/speed limit middleware exists.
- **What’s missing**: Abuse-resistant auth (attestation/per-install secret) and tightened CORS.
- **Gating criteria**: fix STOP_SHIP server auth; verify abuse attempts fail.

## Overall app completeness

- **Overall %**: ~55%
- **How computed**: weighted sum of category completeness (weights above).
- **Confidence in overall %**: MEDIUM (because multiple high-weight categories require device evidence).

## Ready for EKF phase?

- **Decision**: NO
- **Why**: Baseline reliability/security is not yet proven on-device (tracking/alarm delivery under Android constraints), and a STOP_SHIP server abuse risk exists. EKF would improve GPS robustness, but it should not be pursued until the core promise is demonstrably reliable and secure.

- **Gating criteria (must hit before EKF)**:
	1) Resolve STOP_SHIP server auth issue (or remove dependency on the proxy for core operation).
	2) Remove embedded/fallback Maps API key behavior.
	3) Device evidence matrix completed:
		- Screen off + lockscreen alarm delivery
		- Foreground swipe-away (heartbeat pause) + resume
		- Process kill + relaunch restore/cleanup behavior
		- DND/battery saver scenarios
	4) Snapshot persistence made size-bounded + verifiable.

- **Known EKF integration points (future)**:
	- Replace/augment `SensorFusionManager` and dropout handling in `LocationStreamHandler` with EKF state estimator; keep existing “dropout buffer” gating but base it on EKF covariance/innovation.
	- Ensure alarm evaluation consumes EKF-smoothed position + uncertainty, not raw GPS.

- **Current blockers**:
	- OS/device reliability unproven (UNKNOWN/MEDIUM rows in `CERTAINTY_MATRIX.md`).
	- Server proxy abuse STOP_SHIP.
