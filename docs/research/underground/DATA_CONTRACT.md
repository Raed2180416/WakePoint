# Underground-positioning research — DATA CONTRACT (read before any analysis)

Goal: build a **never-late-safe** underground position/stop estimator that uses the
sustained braking/acceleration force (and other robust IMU features) to COUNT stops,
detect dwells, and TIGHTEN the reachability "cone", modeled to SOTA depth (not naive
thresholding). Validate on REAL recorded metro rides; explore car & walking modes.

## The core product invariant (never violate)
The wake alarm must fire NEVER LATE (before the rider's stop) and not absurdly early.
Reachability physics gives the guarantee: `s_max(t) = s0 + V_LINE·(t − t0)` is an UPPER
bound on true along-route progress. Any IMU-derived tightening must only ever move the
estimate in a validated direction and MUST preserve the upper-bound property (a missed
detection may reduce tightening but must never cause a late fire). Prove this for any
method you propose.

## Fixtures (at /home/raed/geowake_imu_analysis/fixtures/)
Each ride = 3 files: `<base>.json`, `<base>_imu.csv`, `<base>_gps.csv`.

**REAL rides (use these to VALIDATE — handheld Android, real Bengaluru Purple line):**
- `fixture_Nadaprabhu_Kempegowda_Metro_Station_Majestic-2025-12-21_07-35-32` — 13 stations, 429 polyline pts, 6 blind windows, leg 20973.6 m.
- `fixture_Nallur_to_Vijaynagar` — 16 stations, 495 polyline pts, 33 blind windows, leg 24044.2 m.

**SYNTHETIC rides (IMU is synthesized; use for scenario coverage, NOT as ground-truth for signal realism):** allunderground_20min, express_skip, long_fullline, short_1stop, short_2stop.

### IMU CSV schema (~50 Hz)
`t_s,ax,ay,az,gx,gy,gz` — timestamp seconds; accel m/s^2 (INCLUDES gravity, body frame);
gyro rad/s (body frame). Handheld phone → dominated by human-handling noise (this is the
whole difficulty; a naive |accel| ZUPT FAILS — stops have MORE energy from people moving).

### GPS CSV schema
`t_s,lat,lng,hacc[,speed]` — speed may be blank/absent. During blind windows GPS is blanked.

### JSON schema (GROUND TRUTH)
- `oriented_polyline`: `[[lat,lng],...]` route geometry, oriented in travel direction.
- `stations`: `[{name, lat, lng, arrival_t_s, s_travel, perp_m}]` — **arrival_t_s** = the
  wall-clock second the train reached that station (ground-truth stop time); **s_travel** =
  along-route arc-length (meters) of that station from the leg start. These two give you the
  ground-truth position-vs-time (piecewise-linear between stations) and the true stop instants.
- `gps_blind_windows_s`: `[[t0,t1],...]` — intervals where GPS was blanked (the "GPS goes dark"
  windows you must estimate position through and compare to ground truth).
- `line`, `leg_length_m`, `device`, `platform`, `synthetic`.

## What "modeled to the max" means (push past naive)
- Proper **attitude/gravity estimation** (complementary/Mahony/Madgwick or EKF) — note the trap:
  a simple low-pass "gravity" estimate is CONTAMINATED by sustained horizontal accel during
  braking (it leaks the brake force into the gravity estimate). Use gyro propagation + accel
  correction only during low-jerk to keep gravity clean.
- Project to the **track/longitudinal axis** (e.g. PCA of horizontal specific force, or align to
  the polyline tangent) → signed longitudinal accel.
- **Δv integration over a short braking event** (bounded drift) with a **zero-velocity-at-station**
  constraint (a brake integrating to −v_cruise is a CONFIRMED full stop).
- **Stop detection as an HMM / matched filter** over states {cruise, brake, dwell, launch} enforcing
  the physical decel→dwell→accel sequence — not a single threshold.
- **Route-constrained position** between confirmed stops via a jerk/accel-limited trapezoidal
  speed profile + the known inter-station distance (from s_travel / polyline) — a physics-anchored
  DR that resets at each station.
- **Particle filter / map-matched** 1-D estimator on the route with event anchors, propagating and
  collapsing uncertainty; report the uncertainty band, not a false point.
- **Mode-adaptive**: still / walk / car / train classification → per-mode motion model & V_LINE
  (walk = PDR step-counting ~1.4 m/s; car = road kinematics, turns; train = trapezoidal-between-stations).

## Deliverables the research must produce (grounded + honest)
1. Cleaned longitudinal-accel signal for the real rides; brake-event SNR vs handling noise.
2. Stop-detection precision/recall/count-accuracy vs ground-truth arrival_t_s.
3. **Position estimate through the blind windows vs ground truth** (the headline: meters of error
   when GPS is dark, vs the current EKF/reachability), with plots/tables.
4. Reachability cone tightening: how much the worst-case early-firing shrinks, with the never-late
   upper-bound proof preserved.
5. Car-underground and walking-underground physics + mode classification.
6. Honest verdict: what works on real handheld data, what needs better placement/more data/other
   sensors (baro/WiFi/cell), and what is device-unproven.

Every empirical claim = a script you ran on the real fixtures + the numbers. Every SOTA claim = a
cited source (WebSearch). Never claim device/real-world proof from a simulation.
