# Along-track GPS position error vs reported accuracy — the never-late precondition (i)

**Question (GW-0181).** GeoWake's never-late bound anchors at `sHi = fixArc + reportedAccuracy`
(`lib/core/reachability/reachability.dart:210-211`) and is only never-late if `sHi >= true
progress` at the fix instant — i.e. **`reportedAccuracy >= (trueArc − fixArc)` measured in the
direction of travel** (the along-track **backward** error; positive = the fix is *behind* the
train = the dangerous direction). If that fails, `sHi < trueArc` and a bound built on that fix
is already LATE. The sim oracle can never produce this failure: `reachability_scale_test.dart`
re-anchors with `sMeters = _trueS(t)` (EXACT true arc) and `accuracyMeters = 10.0`, and the
Python ride generator scatters fixes **perpendicular** to heading only, so along-track error ≡ 0
in simulation. This document measures the quantity from the **real recorded corpus**.

**Verdict:** the precondition is violated by real gate-passing GPS at a **high, non-negligible
rate — ~18% (de-biased best estimate) to ~64% (naive truth) of accepted fixes** — with a worst
observed shortfall of **1,650 m**. The hazard is real and the sim proves `LATE=0` on a fix
stream that structurally cannot contain it. GW-0181 confirmed.

---

## 1. Data, definitions, method

**Corpus (real handheld Android, Bengaluru Purple/Green metro).** Per `DATA_CONTRACT.md`.

| Ride | fixes | gate-pass (hacc≤100) | stations | source |
|---|---|---|---|---|
| Nadaprabhu Kempegowda (Majestic), Purple | 1,645 | 1,616 | 13 | fixtures + gt |
| Nallur → Vijaynagar, Purple | 2,436 | 2,368 | 17 | fixtures + gt |
| Nallur Halli → Vijaynagar, Purple | 615\* | 416 | 19 | gt only |
| Rajajinagar → Nallur Halli, Purple | 649\* | 537 | 18 | gt only |

\* gt series is decimated to ≤600 pts.

**Production semantics measured (verified in code):**
- Accuracy gate: a fix is **accepted iff `hacc` is finite and `hacc ≤ 100 m`**
  (`FireDecisionConfig.defaultAccuracyGateMeters = 100`, applied `location_manager.dart:319`).
- Anchor: `sHi = sMeters + accuracyMeters` (forward overbound only), `reachability.dart:210`.
- **Violation of precondition (i)** ⇔ gate-passing fix with `along_track_backward_error > hacc`.

**Two independent computations** (scripts in `docs/testing/scripts/`, run against
`/home/raed/geowake_imu_analysis`; **do not** invoke flutter):

- **METHOD A (gold — `alongtrack_error.py` / `alongtrack_debias.py`)** — full raw GPS CSV from
  `fixtures/`, **our own** haversine + local-equirectangular snap onto each ride's
  `oriented_polyline` → `fixArc`; `trueArc` from the ride's station `(arrival_t_s, s_travel)`.
  2 rides, 4,081 raw fixes, no decimation.
- **METHOD B (breadth — `alongtrack_error.py`)** — pipeline-snapped `arc_m` per fix and station
  `arc_m` from `ground_truth/gt_*.json` (OSM line polyline). 4 rides.

Travel direction is derived per ride: on the Nallur legs the line arc **decreases** with travel,
so progress = `dir·arc` with `dir = sign(arc_last − arc_first)`; `along_bwd = dir·(trueArc − fixArc)`.

**Ground-truth "true position" — which one, and its artifact.** `trueArc(t)` was computed two ways:

1. **Piecewise-linear station chord** (the `DATA_CONTRACT` model): linear interp of
   `(arrival_t_s → s_travel)`. **This model has a systematic artifact:** it spreads each station
   **dwell** and the **accel/decel** ramps into a constant-speed chord that runs *ahead* of the
   real train mid-segment, manufacturing spurious "backward" error. Proven by binning `along_bwd`
   by time-to-nearest-station (Majestic, gate-passing):

   | time-to-station | median `along_bwd` (linear) | median `along_bwd` (speed-integrated) |
   |---|---|---|
   | 0–5 s (at anchor) | −13 m | −15 m |
   | 15–30 s | **+75 m** | −19 m |
   | 30–60 s | **+151 m** | −57 m |
   | 60–120 s | **+104 m** | −74 m |

   The linear-truth error is ~0 at the anchors and balloons to +150 m mid-segment — a sawtooth =
   pure truth-model artifact, not GPS error.

2. **Doppler-speed-integrated, station-anchored truth (primary/de-biased).** Integrate the GPS
   Doppler **speed** column to get the arc *shape*, then affine-rescale each inter-anchor interval
   so it hits the station arcs exactly. Position truth then comes from **(Doppler speed +
   station anchors), independent of GPS *position* multipath**, and respects dwells/ramps. This
   removes the chord artifact (right column above stays ≈0 or forward). It is the trustworthy
   truth for the headline numbers. (Caveat: Doppler speed is not 100% independent of position,
   and if speed also lags during multipath this truth slightly *under*-counts backward error — so
   the de-biased violation rate is a mild **lower bound**.)

**The real answer lies between the two; best estimate = the de-biased figure.**

---

## 2. Distribution of along-track error (gate-passing fixes)

**De-biased (Doppler-speed truth), Method A, on-route (perp ≤ 50 m), n = 3,799:**

| quantity | value |
|---|---|
| along-track error, all fixes (signed, +=backward) | p50 = **−38 m** (i.e. usually slightly *forward*), p90 = +34 m, p95 = **+87 m**, p99 = **+522 m**, max = **+1,750 m** |
| **BACKWARD** subset (>0), n = 873 (23% of fixes) | median = **30 m**, and **83% of backward fixes (721/873) exceed their reported accuracy** |
| **FORWARD** subset (safe direction) | dominant mass; forward errors *strengthen* `sHi`, harmless for never-late |

**Naive (piecewise-linear chord) truth, pooled Method A, n = 3,984** — *artifact-inflated, shown
for the record*: BACKWARD median = 136 m, p90 = 350 m, p95 = 421 m, max = **1,750 m**;
FORWARD-magnitude median = 24 m, p95 = 179 m.

**Reported accuracy distribution (`hacc`):**
- all fixes: median = **9.9 m**, p90 = 26 m, p95 = 93 m, p99 = 200 m, max = 456 m.
- gate-passing: median = **9.9 m**, p90 = 22 m, p95 = 34.5 m, p99 = max = 100 m.

The core mismatch: **reported accuracy median ≈ 10 m, but the backward-error median among
backward fixes ≈ 30 m** → GPS understates its own along-track backward error by a **median 3.6×**
(p90 = 23×, p95 = 33×, worst = 60×). Reported accuracy is a **2-D CEP-style number and carries
essentially no information about along-track bias/latency** — exactly what the anchor assumes it does.

---

## 3. CRITICAL — fraction of gate-passing fixes that violate never-late precondition (i)

> **Exact fraction (primary, de-biased Doppler-speed truth, Method A, 2 real rides):**
> **724 / 3,984 gate-passing fixes = 18.17 %.**
> On-route only (perp ≤ 50 m): **721 / 3,799 = 18.98 %.**
> Restricted to station-approach fixes (≤15 s from a station, where the fire decision matters
> most and truth is best-anchored): **82 / 492 = 16.67 %.**

> **Naive piecewise-linear truth (artifact-inflated upper value):**
> **2,533 / 3,984 = 63.58 %** (Method A); **1,543 / 2,353 = 65.58 %** (Method B, 4 rides).

> **WORST margin `along_track_backward − hacc` (how far `sHi` fell below true progress) among
> gate-passing fixes: 1,649.8 m.** Among violations the shortfall is median 27 m, p95 ≈ 445–490 m.

**Interpretation.** Even after removing the truth-model artifact, **roughly 1 in 6 accepted GPS
fixes** would seed a never-late anchor that is *already behind the train* — `sHi < trueArc`. A
bound freely propagated from such an anchor is late from the start. The true rate is bounded in
**[18 %, 64 %]**; the 64 % is inflated by the demonstrated dwell/accel chord artifact, so **~18 %
is the defensible figure** (and a mild lower bound). The sim oracle reports LATE = 0 on a fix
stream that by construction contains **zero** such fixes.

---

## 4. Where the violations cluster (de-biased, n = 724)

| cluster | count | share |
|---|---|---|
| **On-route** (perp ≤ 50 m — "looks like a clean fix", median perp = 13 m) | 721 | **99.6 %** |
| Off-route / phantom (perp > 50 m) | 3 | 0.4 % |
| Low speed < 3 m/s (dwell / station approach / departure) | 387 | **53 %** |
| Cruise ≥ 8 m/s | 287 | 40 % |
| Near station (≤ 30 s) | 217 | 30 % |
| Mid-segment (> 60 s from any station) | 303 | 42 % |
| At a blind-window boundary (tunnel mouth) | 49 | 7 % |
| Cold start (≤ 60 s) | 2 | 0.3 % |

**Key finding — the danger is NOT the phantom.** 99.6 % of violations are **on-route** fixes
(median perp 13 m, median hacc 10 m): they pass the accuracy gate, look perfectly snapped, yet sit
behind the train by 3–4× their reported accuracy. Off-route phantoms (perp up to 2.7 km on
Rajajinagar) are visibly rejectable and along-track-violate only ~1.6 % of the time (a
perpendicular error projects near the true arc). Violations concentrate at **low speed — station
approach / dwell / departure (53 %)** — precisely the geometry where the alarm fires — and are
also present in cruise (40 %). This is consistent with **GPS latency/lag** (a fix reported for a
position the train has already left) plus urban-canyon along-track multipath, neither of which the
2-D `hacc` reflects.

---

## 5. Recommended injection model for a deterministic never-late stress test

Feed the never-late evaluator gate-passing fixes (`hacc ≤ 100`) whose **true** along-track
position is **ahead** of `fixArc + hacc` by an injected backward bias `b`, and assert the fire
still precedes the target. Two components, from §2–§4:

**Component 1 — on-route along-track backward bias (dominant; ~19 % hit rate).**
Per accepted fix, with probability **p ≈ 0.19**, inject a backward displacement `b` with reported
accuracy held at the *typical* `hacc = 10 m` (so the anchor believes it is precise). Calibrated
deterministic vectors (understatement factor `k = b/hacc`, from real data: median 3.6×, p95 33×,
max 60×):

| case | `hacc` fed | injected backward `b` | shortfall `b − hacc` (how late `sHi` is) |
|---|---|---|---|
| typical | 10 m | **30 m** (k≈3.6) | 20 m |
| p95 | 10 m | **90 m** (k≈9) | 80 m |
| p99 | 10 m | **520 m** (k≈52) | 510 m |
| worst observed | 10 m | **1,650 m** (k≈60 vs its native hacc) | **1,640 m** |

Concentrate injections at **low speed near a station approach** (53 % of real violations occur
there) to match the fire-decision geometry.

**Component 2 — off-route phantom (rare, ~5 % of accepted fixes).** A gate-passing fix
(`hacc ≤ 100`) whose 2-D position is 200 m–2.7 km off the line; along-track it violates only
~1.6 % of the time but with a fat tail — inject an occasional arc error up to **~1,000 m
backward**. Primarily a test of EKF phantom rejection, not the raw bound.

**Deterministic minimum bar:** the never-late oracle must **not** re-anchor to `_trueS(t)` with a
fixed 10 m accuracy. It must ingest the **as-reported** fix (`fixArc` = snapped noisy position,
`hacc` = reported) and preserve `fire_time ≤ arrival_t_s` under Component 1 at least through the
**p95 (b = 90 m)** vector, and ideally degrade gracefully (widen, not fire late) under the
p99/worst vectors — the physics `V_LINE` free-run must absorb the ~500–1,650 m tail via the
reachability cone, not via a trusted anchor.

---

## 6. Reproduce

- `docs/testing/scripts/alongtrack_error.py` — Methods A & B, full distributions, per-ride +
  pooled violation fractions, cross-validation. Run from `/home/raed/geowake_imu_analysis`.
- `docs/testing/scripts/alongtrack_debias.py` — Doppler-speed truth, time-to-station binning that
  proves the chord artifact, linear-vs-speed violation-rate comparison.
- `docs/testing/scripts/injection_model.py` — on-route/off-route split, understatement-factor
  distribution, injection-model parameters.

Cross-validation A vs B agrees on the clean ride (Majestic: median 89 vs 89 m, p95 356 vs 358 m);
they diverge on off-route arc projection for Nallur (Method B's OSM-line snap throws wild arcs for
phantom fixes) — Method A (own leg-polyline snap, full raw GPS, de-biased truth) is the primary.

**All numbers above are measured, not assumed.** Truth-model limitation stated explicitly: the
headline 18 % uses Doppler-speed truth (mild lower bound); the piecewise-linear 64 % is an
artifact-inflated upper bound. The never-late precondition (i) is empirically violated by real
gate-passing GPS at ~18 % (best estimate), worst shortfall 1,650 m — and the current sim oracle
cannot generate a single instance of it.
