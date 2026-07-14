# Underground Position Anchoring for WakePoint — SOTA (July 2026) + OSS

**Problem.** On a fully-underground trip the 1D-progress EKF (state `[s, v, b]`) dead-reckons on phone IMU with no absolute fix. It drifts 2.5–8.5 km, fires the alarm **late**, yet reports σ≈10–15 m — *confident-wrong*. Dwell-counting is the only in-trip anchor and desyncs permanently on one missed stop. We need **absolute or semi-absolute `s`** anchors that work underground on a commodity phone and fuse **safe-fail**: an ambiguous observation must *widen* σ, never snap to a wrong `s`.

**Top recommendation.** Build toward **magnetic-field map-matching** as the strategic underground anchor — it is the only source here that delivers a *true absolute* re-fix underground (recovers from any drift or dwell desync) on universal phone hardware, and it maps cleanly onto our 1D arc-length filter. But it needs a per-line magnetic map first, so **deploy immediately, in this order, the near-zero-cost safe-fail stack that we already have the ingredients for**: (1) rail-geometry curvature map-matching, (2) schedule/timetable prior with a critical-fractile fire rule, (3) barometric station/descent detection — then crowdsource magnetic maps from rides and promote magnetic to primary.

---

## The safe-fail fusion contract (applies to every anchor)

An anchor enters the EKF as a measurement `z = s_anchor` with covariance `R_anchor`, gated three ways so it can never cause a confident-wrong snap:

1. **Mahalanobis innovation gate.** Reject the update if `(z−s)²/(P+R) > χ²_gate`. A wildly off anchor is discarded, not applied.
2. **Multi-modal → wide `R`.** For fingerprint/sequence anchors, take the *spread of the top-k matches* as `R`. One dominant match → tight `R` (real fix). Ambiguous top-k → huge `R` → the update barely moves `s` but the honest uncertainty is preserved.
3. **Confidence-to-covariance, never confidence-to-mean.** When no anchor fires for T seconds, **inflate process noise `Q`** so σ grows — the filter *admits* it is lost. This alone kills the "σ=10 m while 5 km off" pathology and, with the critical-fractile fire rule (fire at `median_ETA − 2σ`), converts late fires into safe early fires.

This contract is why one-sided anchors (geometry, schedule, baro-descent) are so valuable: by construction they can only *bound* `s`, never relocate it overconfidently.

---

## Ranked anchors (cost-to-implement vs robustness)

| # | Anchor | Underground? | Accuracy | Cost | Robustness | Role |
|---|--------|-------------|----------|------|-----------|------|
| 1 | **Magnetic map-matching** | **Yes — strongest** | sub-5 m (PF) / ≤30 m cold-start | Med (needs map) | **High** — true absolute re-fix | Strategic primary |
| 2 | **Rail-geometry / curvature match** | Yes (on curves) | <10 m on curves | **Low** (geometry prefetched) | Med | Cheapest safe-fail win |
| 3 | **Schedule / timetable prior** | Yes | station-level; bounds drift | **Very low** | Med-low | Safety backstop |
| 4 | **Barometric station/descent** | Yes (event) | descent reliable; station ID coarse | Low | Low-med | Event detector / ZUPT trigger |
| 5 | **Cellular / WiFi / BLE fingerprint** | Platforms only | single-digit-m *if* infra surveyed | **High** (survey + OS limits) | Med (infra-dependent) | Platform anchor if infra exists |

---

### 1. Magnetic-field fingerprinting / map-matching — **primary**
Rails, third rail, rolling stock and tunnel steel create a strong, **stable, spatially-rich** magnetic signature along the track; a phone magnetometer measurably picks up railway fields (`arXiv:2006.06481`). On *operational train data*, a particle filter over a pre-recorded magnetic map reaches **track-selective sub-5 m accuracy over 21.6 km**, and a stateless sequence-alignment method localises **within 30 m in 92 % of cold-starts (100 % using top-3 matches)** (`arXiv:2507.19327`). Magnetic-odometry-aided INS has a **far lower error-growth rate than standalone INS** (`arXiv:2503.04286`).

**Fusion.** `arXiv:2409.01091` ("Online **1-D** Magnetic Field SLAM") is a structural twin of our filter: it stores past magnetometer readings as a **1-D trajectory vs arc-length**, does loop-closure/sequence matching, and fuses matches with odometry increments in an **EKF + smoother** — exactly `s`-indexed. Use the *alignment* variant (top-k with spread→`R`) rather than a hard PF snap, so ambiguous tunnels widen σ instead of teleporting `s`. Device-frame orientation (our known weak point) is handled by **rotation-invariant features** — field norm `Mn` and gravity-axis projection `Mg` — regressed by a lightweight 7-layer CNN (`arXiv:2604.22896`); these need no reliable tilt filter. Map bootstrapping is nearly free for us: WakePoint already prefetches the route and riders repeat lines, so magnetic maps accrue from normal rides.
**OSS:** `github.com/manonkok/1d-magnetic-field-slam` (reference impl of 2409.01091, MATLAB) · `github.com/schollz/find3` (multi-source fingerprinting incl. magnetic, production-grade). Also `arXiv:1804.01926`, `2512.10128`, `2312.05015`.
**Cost/robustness:** medium cost (map + matcher), highest robustness; the only true underground absolute re-anchor → strategic moat.

### 2. Rail-geometry / curvature map-matching — **cheapest immediate win**
We *already* prefetch the route polyline (the rail-geometry skill fetches OSM line + station nodes). Track geometry as a look-up table + IMU in a particle filter keeps **absolute error <10 m during GNSS outages up to 30 s, best on curves and curvy lines** (`arXiv:2406.02339`): the gyro yaw-rate profile is matched against the *known curvature* of the route, giving a semi-absolute `s` fix wherever the line bends. On a 1-D arc this is inherently safe-fail — a manifold constraint can only say "you are somewhere on the line," never confidently off-route.
**OSS:** `github.com/cyang-kth/fmm` (Fast Map Matching, HMM+precomputation, Python/C++, OSM) · `github.com/bmwcarit/barefoot` · Valhalla/GraphHopper. General map-matching SOTA: `arXiv:2108.00439`, `2603.24054`, `1510.03533`.
**Cost/robustness:** low cost (ingredients in hand), medium robustness (informative only on curves; straight tunnels give nothing).

### 3. Schedule / timetable anchoring — **safety backstop**
Known inter-station run times + dwell times give a prior `s_expected(t)` that *bounds* drift even with zero sensor fix. Metro delays are **regular day-to-day and seasonally** (`arXiv:2107.14094`), so the prior is reliable with quantifiable spread. The Connection Scan Algorithm and its **MEAT (Minimum Expected Arrival Time)** variant explicitly propagate *uncertain future delays* (`arXiv:1703.05997`) — the natural way to feed a *distribution* over `s`, not a point. Fuse as a wide-σ soft prior; combined with the **critical-fractile fire rule** (`median_ETA − 2σ`) it guarantees early, never late.
**OSS:** `github.com/transnetlab/transit-routing` (RAPTOR/CSA/TBTR, Python) · `github.com/planarnetwork/connection-scan-algorithm` (TS) · `github.com/chairemobilite/trRouting` (CSA, C++).
**Cost/robustness:** very low cost (data only), medium-low robustness (breaks on express/skipped stops — but wide σ keeps it safe).

### 4. Barometric altimetry — **descent + station-stop event detector**
Most mid/high-end phones expose `Sensor.TYPE_PRESSURE`. Barometric pressure is **far less noisy than accelerometer integration** for vertical motion (`arXiv:1607.00363`) and predicts building floor level accurately (100 % correct floor across 5 NYC buildings, `arXiv:1710.11122`). Published work estimates a rider's subway location from the phone barometer by matching **per-station elevation profiles** (ACM MELT, `dl.acm.org/doi/10.1145/2830571.2830576`) — a station-level *cue*, not an absolute fix. Use to (a) confirm the *transition* to underground, and (b) fire a **ZUPT + candidate-station anchor** at each detected stop — the safe-fail win is that a stop-event resets `v`, not `s`, unless the station is unambiguously matched.
**OSS:** `github.com/schollz/find3` (ingests barometer) · PressureNET (open-source Android barometer). Caveats: barometer absent on some phones; tunnel **piston-effect** pressure transients and HVAC/weather drift must be high-pass filtered.
**Cost/robustness:** low cost, low-medium robustness (event-level, not absolute).

### 5. Cellular / WiFi / BLE fingerprinting — **platform-only, lowest priority**
WiFi/BLE fingerprinting works *where infrastructure and a survey exist*, with low-overhead phone variants an active research line (`arXiv:2106.13663`); 5G gives cm-level in GNSS-challenged/tunnel settings but needs operator infra (`arXiv:2004.07380`); BLE AoA improves platform fixes (`arXiv:2501.08805`); the HYMN multi-tech dataset (`arXiv:2604.20349`) supports fusion research. **Practical blockers for a solo founder:** **iOS forbids raw WiFi scanning** without special entitlements, **Android throttles scans** (since Android 9), and running tunnels rarely have usable APs. Only viable as a *platform* anchor (when a fingerprint DB exists), matched top-k → wide `R`.
**OSS:** `github.com/schollz/find3` · AnyPlace (`anyplace.cs.ucy.ac.cy`).
**Cost/robustness:** high cost (survey + OS limits + infra dependence), medium robustness at platforms only.

---

## Cross-cutting: make the IMU itself honest
Anchors only fail safe if the dead-reckoning core outputs *calibrated* uncertainty. **AirIMU** learns IMU noise + **uncertainty propagation** (`arXiv:2310.04874`, `github.com/haleqiu/AirIMU`); **AirIO** folds it into an **uncertainty-aware EKF** (`arXiv:2501.15659`); **GNIO**'s gated head is a **soft, differentiable ZUPT** (`arXiv:2603.15281`). **SubwayPS** (`arXiv:1904.01675`) is direct prior art for smartphone underground-transit positioning.

## Recommended build order (bootstrapped)
1. **Now (days):** schedule prior + critical-fractile fire rule → immediate late-fire guard. Inflate `Q` on anchor starvation.
2. **Next (weeks):** curvature map-matching against the prefetched OSM geometry (fmm) + barometric descent/stop ZUPT.
3. **Then (the moat):** crowdsource magnetic maps from rides; deploy 1-D magnetic sequence-alignment (rotation-invariant `Mn/Mg`) as the absolute re-anchor. Reserve WiFi/BLE for stations with existing infra.

---

## Verified arXiv IDs (26 cited below — each resolved via the arXiv API this session)
Magnetic: 2507.19327 · 2409.01091 · 2503.04286 · 2604.22896 · 2006.06481 · 2512.10128 · 1804.01926 · 1802.06199 · 2312.05015
Map-matching / track: 2406.02339 · 2108.00439 · 2603.24054 · 1510.03533
Barometric: 1710.11122 · 1607.00363
Cellular/WiFi/BLE: 2106.13663 · 2004.07380 · 2604.20349 · 2501.08805
Schedule: 1703.05997 · 2107.14094
IMU / uncertainty / prior art: 2310.04874 · 2501.15659 · 2603.15281 · 2002.10718 · 1904.01675

**Fake-ID control (confabulation check):** `2505.00000`, `2410.98765`, `2604.99999`, `9999.99999`, `2607.13337` — **all correctly returned not-found**, confirming the verification path rejects invented IDs.
