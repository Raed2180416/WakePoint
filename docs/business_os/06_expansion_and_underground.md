# Business OS — City Expansion & Underground Reliability

Two linked bets from the brief: (1) prove the algorithm works underground / off
-GPS before betting the business on it; (2) expand to cities where the risk is
lowest first. Grounded in `research/underground_validation.md` (fact-checked).

## 1. The strategic sequencing insight

Underground reliability is the moat AND the least-tested part of the system
(per project memory). So the launch sequence should **de-risk reputation first**:
lead with mostly-**overground** metros where GPS is available and the alarm is
easy to get right, bank reliable 5-star reviews, and only lean on
tunnel-precision as the differentiator once the underground algorithm is proven
on real data. Don't make underground reliability the sole hinge on day one.

## 2. Proving underground reliability from public data (no paid data, no beacons)

The honest finding: **no single public dataset gives India-specific,
ground-truth-labeled underground IMU traces.** So the plan is layered, cheapest
first (full method in the research doc):

1. **Self-collect labeled reference rides** (highest value, ~free). Ride Namma
   Metro's Majestic underground stretch logging raw IMU + barometer + GPS at max
   rate, tapping a button at each station as ground truth. This is the only
   India-geometry-matched truth that exists — a metro ticket + time.
2. **OSM way-level tunnel extent.** Query Overpass for the line's member `way`s
   (NOT the route relation — verified: route relations carry no tunnel/layer
   tags) filtered on `tunnel=yes`/`layer<0`; mark those arc-length spans as the
   GPS-denied window to test against. Reuses the existing `wakepoint-rail-geometry`
   skill's stitching pipeline.
3. **Synthetic GPS-denial injection.** Take a real above-ground ride with good
   GPS, blank the GPS channel over a tunnel-length interval, run the EKF in
   dead-reckoning-only mode, compare its re-acquisition estimate to the real fix
   you hid. Known-truth validation, no field work.
4. **SHL dataset Subway class** (free 59-hr preview, no subscription) as an
   out-of-domain real-world stress test — London deep tube, wrong geometry, so
   use it only to catch gross failures (divergence, NaN, unbounded drift), NOT
   to tune parameters.
5. **Accelerometer stop-detection cross-check.** The literature converges
   (85–98% accuracy) on a decel-crest / quiet-dwell / accel-trough station
   signature. Implement one method (STE thresholding or crest-trough) as an
   independent second opinion vs the EKF's dwell logic on your own rides;
   disagreements are bugs to investigate.
6. **Per-line barometer pressure-pair calibration** from your own rides
   (FloorPair/MBFP relative-pressure method — absolute MSL drifts with weather).

This is a concrete autopilot-able research pipeline: steps 2, 3, 5 are code the
free agents can build against the existing harness; steps 1, 6 need you on a train.

## 3. Expansion candidates (overground-first, data-quality-weighted)

Ranked (verified where noted; pull StatCounter Android share per country before
committing — not reliably retrieved in research):

| City | Overground | Official GTFS | Note |
|---|---|---|---|
| **Dubai (RTA)** | ~91% Red Line (verified) | ✅ Dubai Pulse (verified) | Best GTFS+overground combo; but UAE skews higher iOS — check. |
| **Bangkok (BTS only)** | 100% elevated (verified) | unconfirmed | Cleanest zero-tunnel system; sister MRT is ~half underground, so scope to BTS. |
| **Manila (LRT/MRT)** | mostly elevated (verified) | community only | Strong Android market; weaker official open data. |
| **Taipei (TRTC)** | mixed | unconfirmed | Best OSM tunnel tagging found — good as an OSM-quality reference even if not most-overground. |
| **Jakarta** | mixed, small | shapefile only | Weakest pick now; revisit as network matures. |

**India home base stays Bengaluru** (Namma Metro: 74 elevated / 8 underground —
mostly overground already, and it's where the data + rail-geometry tooling
exist). Hyderabad is the strongest India expansion (official monthly GTFS).

## 4. Decision gates

- Do NOT market "works underground" as the headline until step 1+3 show the EKF
  holds re-acquisition error within the never-late cone on real Namma tunnel
  rides. Until then, underground is a bonus, not the promise.
- Do NOT expand to a new city until: OSM rail geometry audited for tunnel
  extent (step 2), station dataset built, and one self-collected reference ride
  validates the geometry. One city done right beats five done blind.
