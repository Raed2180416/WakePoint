## EKF Core — GPS-present tracking + dead-reckoning

**Role in the core promise:** This subsystem is the "brain" that answers the single question the whole app depends on: *how far along the route are we right now, and how sure are we?* It fuses the phone's GPS fixes (when they arrive) with the accelerometer/gyroscope (which keep producing data even in a tunnel where GPS is dead) into one number — `s`, the distance travelled along the planned route in metres — plus an honest uncertainty `σs`. Downstream, the alarm fires when `s` (grown by its uncertainty margin) reaches the destination. So the core promise ("wake the rider before the stop, never late, never wrong place") is only as good as this filter's ability to (a) keep advancing `s` when GPS blacks out underground, and (b) never fabricate progress it doesn't actually have. Almost every design decision below is a deliberate lean toward "fail *early*/short (safe: fires a bit before the stop) rather than late/over-progressed (unsafe: misses the stop)."

**Files:**

| Path | What it does |
| --- | --- |
| `lib/core/ekf/ekf_types.dart` | Plain data classes shared by everything: `EkfMode`, `MotionState`, `EkfPublicState`, `ImuSample`, `GpsFix`, `StationCandidate`, `StationSnapConfirmed`, and the tunable `EkfConfig`. |
| `lib/core/ekf/route_geometry.dart` | Turns the route polyline into maths: projects a GPS lat/lng onto the route to get progress `s`, returns the route's forward-direction (tangent) at any `s`, and converts `s` back to a lat/lng. |
| `lib/core/ekf/ekf_pipeline.dart` | The actual Kalman filter. Holds state `[s, v, b]` (progress, velocity, accel-bias) and the 3×3 covariance `P`. Implements predict (IMU integration), GPS update, ZUPT, station-snap, and all the numerical safety rails. |
| `lib/core/ekf/ekf_orchestrator.dart` | The conductor. Owns the pipeline plus every detector, decides *when* to predict/update, classifies motion, handles GPS-off / cold-start, runs frozen-phantom rejection, and gates station snaps. This is the integration surface the app talks to. |
| `lib/core/ekf/tilt_filter.dart` | Complementary filter that estimates which way is "down" (gravity) so raw accelerometer axes can be levelled and rotated toward the world frame. Produces the forward-acceleration used for dead-reckoning. |
| `lib/core/ekf/motion_classifier.dart` | Decides "stationary / vehicle / human (walking)" each tick from IMU variance and a hand-rolled DFT band-energy, plus EKF velocity. Feeds ZUPT gating and tilt trust. |
| `lib/core/ekf/zupt_detector.dart` | Zero-velocity-update detector: recognises a real stop (train dwelling at a platform) from quiet IMU + low velocity held for a dwell time. |
| `lib/core/ekf/station_association.dart` | On a confirmed stop, picks *which* station we're at from the list of station distances, within an adaptive search window. |
| `lib/core/ekf/degraded_mode.dart` | Hysteresis state machine: are we "degraded" (dead-reckoning) based on σs growth and time-since-last-ZUPT? |
| `lib/core/ekf/gps_degradation_detector.dart` | Hysteresis state machine: is GPS bad (no fix / poor accuracy / high innovation) with debounce so a single glitch doesn't flip modes? |
| `lib/core/ekf/ekf_metrics.dart` | Test-harness scorekeeper: running RMSE, max drift, and worst blackout error vs simulator ground truth. Not in the production alarm path. |
| `lib/core/ekf/ekf_logger.dart` | CSV telemetry ring-buffer (≤10 MB) written to app documents for offline replay/analysis. Non-critical; fails silently. |
| `lib/core/ekf/test_routes.dart` | Hard-coded Bengaluru Purple-Line polylines + station-metre tables used by the replay/validation harness. Not used in production. |

---

### How it works, step by step (the atomic walkthrough)

The filter estimates a 3-element state vector at all times:

- `s` — progress along the route in metres (this is *the* output).
- `v` — speed along the route in m/s.
- `b` — accelerometer forward-bias in m/s² (a slow offset the sensor has even when still).

and a 3×3 covariance matrix `P` where `P[0][0] = σs²`, `P[1][1] = σv²`, `P[2][2] = σb²`, and the off-diagonals are the correlations between them. Everything is one-dimensional *along the route*; the filter never tracks 2-D position — it collapses the world onto the route line via `RouteGeometry`.

#### A. Two input streams enter the orchestrator

From `lib/services/sensor_fusion.dart`:

1. **IMU samples** (~50 Hz, `SensorInterval.gameInterval`) → `EkfOrchestrator.onImuSample(ImuSample)`.
2. **GPS fixes** (whenever Android emits one) → `EkfOrchestrator.onGpsFixAuto(GpsFix)`.
   Plus a synthetic **GPS-unavailable** poke (`onGpsUnavailable`) fired by `sensor_fusion.dart` when no on-route fix has landed for 3 s (`_noFixDegradeThreshold`).

Timestamps come from a monotonic `Stopwatch` (`_imuClock`), not wall-clock, so Doze/clock-changes can't corrupt `dt`.

#### B. Per-IMU-tick path — `onImuSample` (orchestrator lines 133–222)

Every tick, in this exact order:

1. `_tiltFilter.setMotionState(_motionState)` then `_tiltFilter.update(sample)` → estimates gravity direction and a device→world rotation (see §D).
2. `_updateInnovationTimer` — if the last GPS innovation was > 3σ, accumulate `_innovationHighSeconds` (used later to flag "GPS is fighting us → maybe we're walking, not riding").
3. `_pushVarianceSample` — appends accel/gyro magnitudes to a **0.75 s** rolling window; `_pushFeatureSample` appends to a **2.56 s** window for the DFT.
4. Compute `accelVariance`, `gyroVariance` over the 0.75 s window.
5. `_extractMotionFeatures` → DFT band energy (walk band 0.5–2 Hz vs train band 4–6 Hz), needs ≥ 8 samples.
6. `_classifyMotion(...)` → `MotionState` candidate (see §E).
7. `_applyMotionDurationGate` — the candidate must **persist for two decisions ~1.28 s apart** (so ~2.56 s of agreement) before `_motionState` actually flips. This kills flicker but *delays* recognising a stop by up to ~2.5 s.
8. `_pipeline.setMotionState(...)`, then `_updateMode(...)` picks `surface` / `metro` / `degraded` (see §G).
9. `_maybeUpdateZupt(...)` → `onZuptCandidate` → `ZuptDetector.update(...)`; if it confirms, `_handleZuptConfirmed` runs the ZUPT + station-association machinery (see §H).
10. `_maybeColdStartBootstrap(...)` — if no GPS has *ever* arrived and we've had IMU for ≥ 10 s, seed the filter at the origin (see §F).
11. **Gate:** if `!_predictionEnabled`, `return` — no prediction happens until GPS has initialised the filter (or cold-start seeds it). Motion/ZUPT bookkeeping above still ran.
12. If `tiltOutput == null` (bad `dt` etc.), fall back to `_pipeline.onImuSample(sample)` which naively integrates raw `sample.ax` as if it were forward accel, and `return`.
13. Otherwise compute `aFwd = _forwardAccel(sample, tiltOutput)` (see §D) and call `_pipeline.onForwardAccel(timestamp, aFwd)` — the Kalman **predict** step (see §C).

#### C. The Kalman predict step — `EkfPipeline.onForwardAccel` (pipeline 95–277)

1. Guard: not initialised → skip. First-ever tick → just record `_lastImuTs`, skip.
2. `dt = (timestamp − lastImuTs)/1e6`. Then **strict `dt` triage**:
   - `dt ≤ 0` → timestamp regression, skip entirely.
   - `dt > 1.0 s` → a real gap (Doze / OEM sensor-batching in a tunnel — the *target* scenario). Do **not** zero velocity (freezing loses progress and fires late). Instead **coast** at last `v` (clamped ±25 m/s), advance `s` by `v·dt` **capped at ±1500 m**, forbid reverse if `!_allowReverse`, and inflate covariance by `(1+min(dt,60))²`. Then `return`.
   - `dt < minDt (0.001)` or `dt > maxDt (0.2)` → marginal; inflate `P` by 1.1 and skip integration.
   - Otherwise proceed.
3. Degraded mode only: inflate `P` by **1.0002** per tick (≈ +1 %/s at 50 Hz → σs 10 m → 27 m after ~100 s), so uncertainty grows *honestly* while dead-reckoning, but slowly enough that station association still works for a few minutes.
4. `aBias = aFwd − b`. In degraded mode while *moving*: deadband `|aBias|<0.1 → 0`, clamp to ±1.5 m/s². In degraded mode while *stationary and v<0.3*: apply velocity damping `×0.98/tick`.
5. Clamp `v` to ±25 m/s (90 km/h — a physical metro ceiling) **before** integrating.
6. Integrate: `s += v·dt + ½·aBias·dt²`; `v = (v + aBias·dt)·vDamping`; re-forbid reverse; re-clamp `v` to ±25.
7. Covariance propagate: `P = F·P·Fᵀ + Q` with
   `F = [[1, dt, −½dt²],[0,1,−dt],[0,0,1]]` and
   `Q = diag(σaccel²·dt⁴/4, σaccel²·dt², σbias²·dt)`, using `σaccel=0.15`, `σbias=0.001`.
8. Push `aFwd` to a 50-sample buffer (for GPS-derived bias observability later).
9. Numerical hygiene chain (runs after *every* update, see §I): `_sanitizeCovariance` → `_enforceSymmetry` → `_applyStateBounds` → `_applyCovarianceFloors` → `_updatePublicProgress`.

#### C′. The GPS update — `EkfPipeline.onGpsFix` (pipeline 292–447)

Reached via `orchestrator.onGpsFixAuto` → `onGpsFix(fix, innovationSigma)` → `pipeline.onGpsFix(fix)`.

1. `sGps = route.projectLatLng(lat,lng)`; if NaN (off-route), **return without touching state** (the orchestrator already redirected off-route fixes to `onGpsUnavailable`, see §J).
2. Not initialised → `_initializeFromGps(sGps, speed)`: set `s=sGps`, `v=max(0,speed)`, `b=0`, `P=diag(25², 5², 0.1²)`.
3. `_enforceCovarianceConsistency()` **before** computing any gain (the 518 km-spike root-cause fix, §I).
4. Innovation `ν = sGps − s`; normalised `|ν|/σs`.
   - `> 15σ` → **hard reset** via `_initializeFromGps` (teleport / total GPS failure).
   - Huber weight `w = min(1, 2.5/|norm ν|)`; if `w < 0.2` (≈12.5–15σ) → **soft reject**, inflate `P` by 1.2, return.
5. Measurement noise `R = max(accuracy², gpsFloorVar=625) / w` (the 25 m floor means even a "3 m" fix is trusted only to 25 m; inflating R for outliers down-weights multipath).
6. Scalar Kalman update on position: `k0=P00/(P00+R)`, `k1=P10/(P00+R)`, **`k2` forced 0** (bias is *not* updated by GPS — bias is only observable during ZUPT). Update `s,v` and the top-two rows of `P`.
7. **GPS-speed fusion** (if `speed` finite): a second scalar update treating `speed` as a direct measurement of `v` with variance `gpsSpeedVar=1.0`. Keeps `v` realistic so DR doesn't start from a stale velocity when GPS later drops.
8. **GPS-derived bias observability** (El-Sheimy 2004): if two fixes are 0.5–5 s apart, `aGPS=Δspeed/Δt`, compare to the mean of the recent IMU `aFwd` buffer, nudge `b` by `0.05·(estimate−b)`, clamp `|b|≤1.0` (only if estimate `<2 m/s²`).
9. Hygiene chain.

#### D. Forward-acceleration extraction — `_forwardAccel` (orchestrator 789–848) + `TiltFilter`

- `TiltFilter.update` maintains a unit gravity estimate `ĝ` in the device frame via a **complementary filter**: predict `ĝ` by integrating the gyro (`ĝ += (ω × ĝ)·dt`), correct toward the accelerometer/gravity-sensor direction with a motion-gated blend factor `α`. `α = 0.05` when confidently stationary; a tiny `α ≈ 0.002–0.005` when `|a|≈g` and gyro/accel agree (to bleed off gyro drift without leaking lateral accel); `α = 0` (pure gyro) during hard accel/brake. A divergence check (`acos(ĝpred·ĝmeas) > 0.01 rad`) treats large accel/gyro disagreement as linear acceleration, not tilt.
- It outputs `gravityDevice` and `rDeviceToWorld = R_y(pitch)·R_x(roll)` built **from pitch & roll only**.
- `_forwardAccel`: subtract gravity (`a − ĝ·9.81`), rotate to "world", then `aFwd = world[0]·tangent[0] + world[1]·tangent[1]` where `tangent = route.tangentAt(s)` is the east/north unit direction of the route.
- **Static bias pre-init:** before GPS, while IMU is quiet (`accelVar<0.5, gyroVar<0.1`), collect `aFwd` into a 100–500-sample window; once ≥100 samples and `|mean|<0.5`, store `_estimatedInitialBias`. This is subtracted from `aFwd` **only in degraded mode**.

#### E. Motion classification — `MotionClassifier.classify` (motion_classifier 95–160)

Order of decisions:
1. **Velocity hard gate** (non-degraded only): `|v|>1.0 m/s → vehicle` (can't be stationary if clearly moving).
2. **Degraded movement gate**: if degraded and `recentMaxAFwd>0.15 m/s²` → `vehicle` (prevents v getting stuck at 0 during DR).
3. Score: `imuStationary = accelVar<0.5 && gyroVar<0.10`; `ekfStationary = σv<0.5`; `score = 0.7·imuStationary + 0.3·ekfStationary`; `score≥0.5 → stationary`.
4. If FFT disabled → `vehicle`. Else walk-band > train-band → `human`; or sustained high innovation (`innovationHighSeconds≥10` or `innovationSigma>3`) → `human`; else `vehicle`.

#### F. Cold-start bootstrap (GLMT-03) — `_maybeColdStartBootstrap` + `pipeline.bootstrapColdStart`

Guarded so it runs **only** if `!_anyGpsFixSeen && !_ekfInitialized && !_coldStartBootstrapped`. After `_coldStartWarmupSeconds = 10 s` of IMU with zero fixes, seed `s=0, v=0, b=0, P=diag(50², 5², 0.1²)` and enable prediction, so an underground boarding with no first fix can still dead-reckon and eventually arm the alarm. A later real fix flows through the normal update; a big seed-vs-fix mismatch trips the >15σ hard reset and re-anchors.

#### G. Mode selection — `_updateMode` (orchestrator 581–628)

- Never had an on-route fix (`!_hasGpsFix`) → force `degraded`.
- Else run `DegradedMode.update` (σs limit 150 m surface / 2000 m metro; also degrades if no ZUPT for 10 min).
- Enter `degraded` if **either** `GpsDegradationDetector.isDegraded` **or** `DegradedMode.isDegraded`. Otherwise `metro` or `surface` by `_isMetroLeg`.

#### H. ZUPT + station snap — `_handleZuptConfirmed` (orchestrator 496–579) + pipeline

On a confirmed ZUPT: `_pipeline.onZuptConfirmed()` runs a velocity-measurement update (`ν = 0 − v`) that *does* update bias `b` (ZUPT is the only place bias is observable), then tightens **σv only** to ≤ 0.5 m/s (deliberately **not** σs — a stop tells us we're still, not *where*). Then `StationAssociation.selectCandidate` picks a station within window `3σs + adaptiveMargin`; if exactly one candidate (or degraded "nearest-ahead" fallback), `pipeline.onStationCandidates([...])` runs a position update snapping `s` to the station. Finally the **§24.2 confidence gate**: only emit `StationSnapConfirmed` if post-snap `σs ≤ 30 m` (≤ 60 m degraded) **and** the station index is strictly greater than the last snapped one (monotonic).

#### I. Numerical safety rails (the reliability story)

- `_applyStateBounds`: NaN/Inf → 0; clamp `s ∈ [0, routeLen+5000]`; clamp `v ∈ ±25`; clamp `|b| ≤ biasLimit(0.5)`.
- `_applyCovarianceFloors`: floor σs (5 m, or 20 m if `noGyro`), σv (0.1), σb; then re-enforce consistency.
- `_inflateCovariance`: multiply diagonals, clamp σs ≤ **3000 m**, σv ≤ 100, σb ≤ 1.
- `_sanitizeCovariance`: hard element caps (P00 ≤ 1e8, etc.) against NaN/Inf.
- `_enforceSymmetry`: `P = (P+Pᵀ)/2`.
- `_enforceCovarianceConsistency`: clamp every off-diagonal to its Cauchy–Schwarz ceiling `|Pij| ≤ √(Pii·Pjj)`. **This is the documented root-cause fix for a 518 km single-tick spike:** during long DR with no position fix, `P01` had drifted to ~110 000× its legal ceiling, so the next ZUPT gain `k0=P01/(P11+r) ≈ −4.4e6` detonated `s`. Enforcing consistency before every gain keeps all gains finite.
- `_updatePublicProgress`: `_sPub` is the **monotonic, rate-limited (≤ +1600 m/tick)** published progress on the surface/metro; **in degraded mode `publicState.s` exposes internal `_s` directly** so the monotonic clamp can't freeze DR.

---

### Key types & functions

- `EkfPublicState { s, v, sigmaS, sigmaV, biasA, mode, motion }` — the immutable snapshot the app reads each tick.
- `EkfConfig` — all tunables (defaults: `sigmaAccel 0.15`, `sigmaBias 0.001`, `gpsFloorVar 625`, `gpsSpeedVar 1.0`, `zuptVar 0.0025`, `stationVar 100`, `minDt 0.001`, `maxDt 0.2`, `sigmaSFloor 5`, `sigmaVFloor 0.1`, `biasLimit 0.5`, `stationSnapSigmaGate 30`). Note `softGateSigma/hardGateSigma` are declared but the pipeline hard-codes 2.5σ Huber / 15σ reset instead.
- `EkfOrchestrator.onImuSample(ImuSample)` — per-tick entry; runs detectors then predict.
- `EkfOrchestrator.onGpsFixAuto(GpsFix)` — production GPS entry; does off-route + frozen-phantom rejection before fusing.
- `EkfOrchestrator.onGpsUnavailable(Duration)` — mark GPS silent; keep DR alive.
- `EkfOrchestrator.publicState → EkfPublicState` — output getter (delegates to pipeline).
- `EkfOrchestrator.onStationSnapConfirmed` (callback) — gated station snaps out to the app.
- `EkfPipeline.onForwardAccel(Duration, double aFwd)` — Kalman predict.
- `EkfPipeline.onGpsFix(GpsFix)` — Huber-robust GPS update + speed fusion + bias observability.
- `EkfPipeline.onZuptConfirmed()` / `onStationCandidates(List<StationCandidate>)` — velocity / position corrective updates.
- `EkfPipeline.bootstrapColdStart({s0=0})` — GPS-denied seeding.
- `EkfPipeline.innovationSigmaForS(double) → double` — how many sigmas an on-route projection is from current `s` (used by the orchestrator to score a fix).
- `RouteGeometry.projectLatLng(lat,lng) → double` — GPS → `s` (NaN if lateral error > 75 m).
- `RouteGeometry.tangentAt(s) → [east,north]`, `positionAt(s) → LatLng`.
- `MotionClassifier.classify(...) → MotionState`; `ZuptDetector.update(...) → bool`; `StationAssociation.selectCandidate(...) → StationAssociationResult?`.
- `GpsDegradationDetector` / `DegradedMode` — the two hysteresis machines gating `degraded`.

---

### Design decisions (the WHY)

1. **1-D "progress along route" state, not 2-D position.** *Why:* the only thing the alarm needs is distance-to-stop; collapsing the world onto the known route line makes the filter tiny (3 states), cheap on a budget phone, and immune to lateral GPS wander. *Trade-off / rejected:* a full 2-D/3-D INS would be far heavier and would drift laterally with no route to anchor it. *Flaw:* it is only correct if the rider is *on the planned route*. Any reroute, wrong-train, or parallel-line situation breaks the mapping, and off-route fixes are simply discarded (treated as GPS-out), so the filter can dead-reckon confidently down a route the rider already left.

2. **Fail-forward on long gaps: coast, don't freeze (`dt>1s`).** *Why:* a tunnel Doze/sensor-batching gap that froze `v→0` under-progressed and fired *late* (measured: a 300 s gap lost 2.85 km). Coasting at last velocity keeps advancing, and firing slightly early is the safe direction. *Trade-off:* if the train actually *stopped* during the gap, coasting over-progresses. They cap the coast at ±1500 m/gap to bound the damage and inflate σ to stay honest. *Flaw:* a 1500 m fabricated coast can still be a whole inter-station span — enough to snap to the wrong station or fire at the wrong place if a station snap doesn't correct it.

3. **Hard velocity clamp ±25 m/s everywhere `s` integrates.** *Why:* non-predict paths (GPS-speed fusion, ZUPT, snap) set `v` without re-clamping; a transient blew `v` to ~1091 m/s and produced a ~518 km spike. Clamping before integration guarantees `s` can never advance faster than a real train. *Trade-off:* genuinely-fast intercity rail (>90 km/h) would be under-integrated. Fine for metro; a latent bug for mainline trains.

4. **Cauchy–Schwarz covariance consistency before every gain.** *Why:* the documented root cause of the 518 km spike — the position/velocity cross-covariance drifted 110 000× past its legal ceiling during long DR, detonating the next ZUPT gain. Enforcing `|Pij|≤√(Pii·Pjj)` keeps all gains finite and is a no-op on a healthy filter. *Trade-off:* none meaningful; it's a correctness guarantee. *Flaw:* it's a *symptom guard* layered on top of a filter that still lets `P` drift into pathology between guards — the underlying reason `P01` grows unbounded during measurement-starved DR isn't removed, just clamped.

5. **Huber robust GPS gating (2.5σ down-weight, 15σ reset) instead of a hard chi-square gate.** *Why:* urban/multipath GPS errors are heavy-tailed; a Gaussian hard-gate either rejects good fixes or accepts multipath. Huber trusts fixes fully within 2.5σ, softly down-weights outliers, and only nukes at 15σ. *Trade-off:* a *sustained* biased multipath stream (all ~3–10σ, same direction) is down-weighted but still slowly pulls the filter the wrong way. *Flaw:* the 15σ hard reset assumes a lone teleport; a cluster of consistent bad fixes never trips it.

6. **GPS never updates bias; ZUPT is the only bias observer.** *Why:* in a constant-velocity model accel-bias is unobservable from position/velocity, so letting GPS touch it injects noise. A true stop (`v=0`) makes bias observable, so bias is corrected there. *Trade-off:* between stops, bias is only weakly nudged by the noisy GPS-derived-acceleration heuristic (gain 0.05). *Flaw:* on a long non-stop tunnel run with no ZUPT, an unmodelled bias integrates into unbounded position drift — exactly the hardest case for the core promise.

7. **Monotonic, rate-limited public progress on the surface; raw internal `s` in degraded mode.** *Why:* a single-tick internal spike must not latch into the number that fires the alarm, so surface/metro publish `max(prev, s)` capped at +1600 m/tick. Degraded mode exposes raw `_s` so the monotonic clamp can't freeze dead-reckoning. *Trade-off:* monotonic means a legitimate *backward* correction (GPS says we over-shot) is ignored on the surface — the filter can only ever agree it's further along. *Flaw:* if a bad surface fix over-progresses `s`, the monotonic clamp makes it permanent → risk of firing early / at the wrong place, and it never self-heals downward.

8. **Cold-start seeds `s=0` at the route origin.** *Why:* an underground boarding that never gets a first fix would otherwise stay uninitialised forever and never arm the alarm; seeding at the origin with wide σ lets DR carry progress. *Trade-off / FLAW:* it *assumes the rider boards at the start of the route*. If they board mid-route with no GPS, DR is anchored kilometres behind reality — a direct "wrong place / late" failure of the core promise. The wide σ helps the fractile fire earlier but cannot fix a wrong origin.

9. **Frozen-phantom rejection (moved <2 m while filter says v>2 m/s → treat as GPS-out).** *Why:* the OS fused provider emits confident stationary fixes underground (proven: 120 s pinned at 3.79 m accuracy); anchoring to that lie drives `v→0` and fires late. *Trade-off:* a genuine platform stop reads `v≈0` and is *not* rejected, so it still fuses — good. *Flaw:* the check needs the filter to already believe `v>2`; if drift has already pulled `v` below 2, the phantom is accepted. And `_lastFixLat` is only set on accepted on-route fixes, so the very first fix can never be phantom-checked.

10. **Off-route fixes are redirected to `onGpsUnavailable`, not discarded silently.** *Why:* discarding a NaN projection while the detector still thought GPS was "live" meant the filter never entered degraded DR. Routing off-route fixes to "unavailable" forces DR to engage. *Trade-off:* legitimate brief route-geometry mismatches (GPS 80 m off a coarse polyline) look "off-route" and suppress otherwise-good fixes. *Flaw:* the 75 m `maxLateralErrorMeters` threshold is a blunt instrument — a sparse polyline on a curve can push a good fix past 75 m and get it dropped.

11. **Two-of-two motion-duration gate (~2.56 s to flip state).** *Why:* raw per-tick classification flickers; requiring persistence stabilises mode and prevents ZUPT/damping thrash. *Trade-off:* it *delays* recognising a stop by up to ~2.5 s, delaying ZUPT/bias-correction at exactly the platform where we most want it. *Flaw:* on short dwells (train stops <5 s), the gate can miss the stop entirely, forfeiting the bias correction.

12. **σs allowed to grow to 3000 m in DR (was clamped to 200 m).** *Why:* clamping σs to a falsely-confident 200 m made the fire-fractile margin too small → fires close to late. Letting σs grow honestly to 3 km makes the alarm fire earlier (safe) and hands station-association a fallback (nearest-ahead / dwell-ordinal) that doesn't depend on the geometric 3σ window. *Trade-off:* a 3 km σs geometric window would make *every* station a candidate; they rely on the degraded fallback selectors instead. *Flaw:* honest-but-huge σs means the alarm may fire very early on a long blackout — safe for "never late," but a poor user experience (waking minutes before the stop) and, per decision 8, useless if the anchor was wrong.

13. **GPS variance floored at 25 m (`gpsFloorVar=625`).** *Why:* Android accuracy numbers are optimistic; a floor stops the filter from over-trusting a "3 m" fix and locking onto multipath. *Trade-off:* genuinely excellent fixes converge slower than they could. Conservative and aligned with the safety bias.

14. **Tilt via complementary filter with motion-gated α, gravity-sensor blend.** *Why:* pure gyro integration drifts ~1–3°/min (→ hundreds of metres of DR error); always bleeding a little accel/gravity reference when `|a|≈g` corrects drift without leaking lateral acceleration into "down." *Trade-off:* during sustained hard acceleration (`α=0`) tilt is pure-gyro and drifts. *Flaw:* see the heading gap in decision 15 — a good "down" estimate still doesn't give a good *forward* estimate.

15. **Forward accel = level-and-project onto route tangent, with NO yaw/heading tracking.** *Why:* the rotation matrix is built from pitch & roll only, which levels the phone; the dominant metro signal (longitudinal surge/brake) is then dotted onto the route's east/north tangent. *Trade-off:* avoids needing a reliable magnetometer/heading underground (magnetometers are useless near trains). **FLAW (significant):** without yaw, `world[0]/world[1]` are horizontal accelerations in a frame rotated by the phone's *unknown* orientation about vertical, but the route tangent is in *true* east/north. Dotting them is only correct if the phone's axes happen to align with the route — in general `aFwd` mixes forward and lateral acceleration. This is precisely why the design leans so hard on ZUPT and station-snaps rather than trusting IMU integration; between corrections, the forward-accel signal is heading-inconsistent and pure DR accuracy is limited.

16. **Sample-rate assumptions are inconsistent across the code.** Several windows are sized for 100 Hz (`_aFwdWindowSize=50 "~0.5s at 100Hz"`, `_biasInitMinSamples=100 "~1s at 100Hz"`) while the pipeline's accel buffer comments say 50 Hz and the actual sensor stream is `gameInterval ≈ 50 Hz`. *Effect / FLAW:* those windows are ~2× longer in wall-time than their comments claim (the "1 s" bias-init window is really ~2 s at 50 Hz). Not catastrophic, but the tuning constants and their justifications don't match the real cadence, so the calibration is softer than documented.

17. **ZUPT/station thresholds are calibrated on the replay corpus, not broadly on-device.** The `ZuptDetector` and `MotionClassifier` comments explicitly cite "test IMU" ranges (`accelVarThresh=1.0`, "test IMU ~0.35–0.9"). *Trade-off:* fits the Bengaluru validation rides well. *Flaw:* real phones vary in accelerometer noise floor, mounting (pocket vs hand vs mount), and case damping; thresholds tuned to the corpus can both false-trigger ZUPT (snapping to a wrong station mid-cruise) and miss real stops on a noisier device.

18. **Two dead / near-dead hooks left in the orchestrator.** `onMotionFeatures` (lines 414–438) classifies then does literally nothing with the result ("no-op for now"). `MotionState.human` can only be produced in degraded mode and is never consumed by the pipeline (only `stationary` affects damping). *Flaw:* these are wiring stubs that make the code look more capable than it is — walking-vs-riding discrimination is effectively inert in the filter.

19. **Metro vs surface mode barely differ in the maths.** The predict/update code doesn't branch on `metro` vs `surface`; the label only changes the degraded σs threshold (2000 m vs 150 m) and which mode string the alarm evaluator sees (the evaluator uses EKF progress for metro & degraded, but *not* plain surface — surface uses GPS-projected progress directly). *Flaw:* the three-mode enum implies more behavioural difference than exists; most of the DR machinery only actually engages in `degraded`.

20. **Linear O(N) route scans per call.** `projectLatLng` scans all polyline segments each GPS fix, and `tangentAt` does a linear `_segmentIndexForS` scan **every IMU tick** (~50 Hz). *Trade-off:* simple, no index structure to maintain. *Flaw:* on a long/dense polyline this is real per-tick CPU on a cheap phone; `tangentAt` also returns only a 2-D tangent, so any route gradient (elevation) is dropped from the forward-accel projection.

---

### Invariants (what must always hold)

- After any update, `P` is symmetric, finite, PSD-consistent (`|Pij|≤√(Pii·Pjj)`), with σs ∈ [floor, 3000 m], σv ∈ [0.1, 100], σb ∈ [floor, 1].
- `s ∈ [0, routeLength+5000]`; `v ∈ [−25, 25]`; `|b| ≤ 0.5`. No NaN/Inf escapes a public state.
- Published `s` is monotonic non-decreasing and rises ≤ 1600 m per tick **in surface/metro**; in degraded mode `publicState.s` may move backward (raw internal `_s`).
- Prediction only runs when `_predictionEnabled` (after first GPS fix *or* cold-start seed).
- Bias `b` is only corrected by ZUPT (and the weak GPS-derived-accel nudge); GPS position/station updates force `k2=0`.
- A station snap is only *emitted* when post-snap σs ≤ 30 m (≤60 m degraded), exactly one candidate, and station index strictly increasing.
- Cold-start seeding can occur at most once and never after any GPS fix has been seen.

### Interfaces (consumes / exposes)

- **Consumes** IMU + GPS from `SensorFusionManager` (`lib/services/sensor_fusion.dart`): `onImuSample`, `onGpsFixAuto`, `onGpsUnavailable`, `setStationContext(stationMeters, isMetroLeg)`, `setNoGyro`, `setFftEnabled`. Route polyline arrives as `RouteGeometry.fromPoints(...)` built in `lib/services/tracking/location_stream_handler.dart`.
- **Exposes** `EkfPublicState` every tick via `orchestrator.publicState`, streamed by `SensorFusionManager._ekfStateController` → `LocationStreamHandler` → `TrackingService._lastEkfState`. The alarm evaluator (`trackingservice.dart` ~1213–1221) uses `ekfState.s` as the authoritative progress **only when the step is metro or the EKF mode is `degraded`/`metro`**; plain surface steps use GPS-projected progress instead. `sigmaS` feeds the downstream critical-fractile/backstop logic (documented in the alarm subsystem).
- **Emits** `StationSnapConfirmed` via `onStationSnapConfirmed` → `SensorFusionManager` → `ActiveRouteManager.onStationSnapConfirmed`.
- **Uses** `RouteGeometry` internally (`projectLatLng`, `tangentAt`, `positionAt`, `totalLengthMeters`) and the detector cluster (`TiltFilter`, `MotionClassifier`, `ZuptDetector`, `StationAssociation`, `DegradedMode`, `GpsDegradationDetector`).
- **`ekf_metrics.dart`, `ekf_logger.dart`, `test_routes.dart`** are consumed by the replay/test harness (`ekf_test_controller.dart`, `imu_replay_engine_v2.dart` — out of this subsystem's scope), not the production alarm path.

### Gaps & flaws vs the core promise (brutally honest)

- **Wrong-origin cold start is a "wrong place / late" landmine.** GPS-denied boarding seeds `s=0`; a rider who boards mid-route underground gets DR anchored kilometres behind truth, and no amount of honest σ fixes a wrong anchor (decision 8). This is the single biggest correctness risk for the promise.
- **Pure dead-reckoning is heading-inconsistent.** No yaw tracking means `aFwd` mixes forward and lateral accel (decision 15); between ZUPT/station corrections, IMU-only progress is only roughly right. A long tunnel run with *no* intermediate stops (so no ZUPT, no snap) has nothing to correct drift, and unmodelled bias integrates unbounded (decision 6). The design mitigates this by firing *early* as σ grows — safe for "never late," but it means the "never *wrong place*" half leans on stations existing to snap to.
- **Monotonic surface progress can't self-correct downward.** An over-progressed bad surface fix latches permanently (decision 7) → early/wrong-place risk with no recovery.
- **Robust gating handles single outliers, not biased streams.** Sustained consistent multipath (all ~3–10σ same direction) is down-weighted but still drags the estimate; the 15σ reset never trips (decision 5).
- **Coast cap of 1500 m per Doze gap can be a full inter-station span** of fabricated progress (decision 2) — safe-direction but capable of a wrong-station snap.
- **Tuning is corpus-fit and rate-inconsistent.** ZUPT/motion thresholds are calibrated on the Bengaluru replay rides and several windows are sized for the wrong sample rate (decisions 16–17); on-device behaviour across cheap Android phones is *not* proven by these constants.
- **Metro speed ceiling ±25 m/s** silently under-integrates any transit faster than 90 km/h (decision 3) — fine for the stated metro target, latent for mainline/express rail.
- **Inert capability stubs** (`onMotionFeatures`, `MotionState.human`) suggest walk/ride discrimination that the filter does not actually act on (decision 18), so a rider who alights and walks the last stretch is not distinguished by the EKF itself.
- **No route-topology awareness.** Off-route/reroute/wrong-train all collapse to "GPS unavailable," so the filter will confidently dead-reckon along a route the rider has already left (decision 1) — the alarm would fire relative to the *old* route.
