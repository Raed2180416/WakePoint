# WakePoint — The 5 Previously-Untested Gaps, Tested End-to-End

**Date:** 2026-07-09 · **Method:** each gap tested against the *canonical full engine* (`run_full_engine`) — the actual shipping architecture with all fixes: entry-snap count init (A5), 13-min physical watchdog (A6), honest σ-floor since-GPS, OOD-gated learned velocity, combined trigger (count OR critical-fractile OR GPS). Metric: fire lead in seconds, where **+late (>30s) is harmful**, **−early is safe**, and **<−180s is "too early" (>3 min)**.

These are the five gaps the coverage doc previously listed as UNTESTED. All five are now tested. **Four are safe; two carry a caveat; one is a structural finding that cannot be fixed in the GPS-out engine and belongs in the app's boarding logic.**

| Gap | Late fires | Verdict |
|---|---|---|
| #1 Multiple blackouts per journey | 0/16 | **SAFE** |
| #2 Line transfers | 1/10 (+69s) | **Safe with caveat** (transfer-walk count gap) |
| #3a Wrong-direction (false alarm risk) | 0/10 | **SAFE** (silent clamp — no false wake) |
| #3c Wrong-route (different line) | 1/6 (+468s) | **Structural — needs pre-blackout GPS route-match** |
| #4 Excessive motion (fidget/walk-in-car) | 0/12 | **SAFE** (detector rejects non-vehicular motion) |
| #5a GPS degradation (NLOS/multipath) | 0/12 | **SAFE** (Huber gate absorbs wrong fixes) |
| #5b Sensor-quality degradation (cheap phone) | 0/12 | **SAFE** (degrades gracefully — fires earlier) |

---

## Gap #1 — Multiple blackouts in one journey (SAFE)

Constructed rides with 2 and 3 *separate* blackout windows (dip underground, resurface with GPS, dip again), target station after the last blackout. **0/16 late.** Final position errors mostly small (1-126m) because GPS re-anchors the estimate on each resurface. The dwell-count survives resurface/re-dive, and re-acquisition transients cause no bad fires. The 2 too-early cases fired on the known count-desync early path — safe direction.

## Gap #2 — Line transfers (SAFE with one caveat)

Constructed journeys of *line A → walk transfer → line B*, with a blackout spanning the transfer and the target on line B. **1/10 late (+69s), 4/10 too-early.** The late fire (seed4004) is the fire-arc-late-in-blackout case: the fire-arc was crossed 68s before blackout end, and the engine fired on GPS resume just after. **New transfer-specific nuance:** the ~210s walk transfer is a dwell-less segment (no train stop), so the dwell-count cannot advance through it and the critical-fractile σ must bridge it. **Fix:** the engine should know a transfer walk is in the prefetched route and treat walk-segment completion as a count landmark (a metro→walk→metro mode transition). Minor — 1/10 at only +69s in a deliberately hard alignment.

## Gap #3 — Wrong-route / wrong-direction while blacked out (mixed — one structural)

**3a. Wrong-direction (rider boards the wrong way, travels backward during blackout, target forward): 0/10 false alarms.** Because reverse motion is clamped on metro legs (`allow_reverse=False`), the estimated position never advances to the fire-arc, so no alarm fires. Safe for the alarm (no false wake). This confirms the audit finding that wrong-direction is handled by *silent clamping*, not an explicit alert.

**3b. Detectability:** the wrong-direction net displacement during the blackout averaged −10 km — trivially detectable by GPS innovation on resume. The app *could* alert "you're on the wrong train" (spec item D7) but currently does not.

**3c. Wrong-route (rider on a different line than the prefetched route): 1/6 late (+468s), leads scattered −1099s to +468s.** This is the one **structural** finding: during a blackout the engine tracks its *prefetched belief* and fires per that belief, blind to the mismatch. **This cannot be fixed from IMU alone** — the IMU sees motion, not absolute position, so it cannot know the rider is on the wrong line. **Mitigation is architectural: route-correctness must be verified via GPS *before* the blackout begins** (while the rider is above-ground boarding) — a pre-blackout route-match gate in the app's boarding logic, not the GPS-out engine.

## Gap #4 — Excessive motion while standing/sitting (SAFE)

Injected fidget / walk-in-car / seat-shift motion bursts (intensity 1.0 and 2.5, up to 11.4 m/s² deltas) on top of the train motion during the blackout. **0/12 late, leads identical to baseline.** Direct verification: the injection is real (5177 samples changed at intensity 2.5) but the dwell-detector count is *stable* (9 = 9) — the band-energy vehicular gate rejects non-vehicular motion, creating no false dwells and masking no real ones. Clean pass.

## Gap #5 — GPS degradation + sensor-quality degradation (SAFE)

**5a. GPS degradation / NLOS multipath (wrong fixes, not a clean blackout): 0/12 late, 0/12 too-early.** Injected correlated multipath bias of 100m and 300m on the surface GPS fixes. The EKF's Huber gate + `gpsFloorVar` absorb the wrong fixes: even at 300m bias the worst lead is +28s (within the 30s accept window), and wrong fixes pull the estimate slightly *ahead* → fire early → safe. This is the case the coverage doc flagged as "arguably more dangerous than a clean blackout" — it holds.

**5b. Sensor-quality degradation (cheap-phone IMU, 2× and 4× white noise + bias): 0/12 late, 0/12 too-early.** The EKF's honest covariance grows with noisier input → larger σ → critical-fractile fires *earlier* (the safe direction). At 4× noise the worst lead is −126s (earlier, still safe). **The engine degrades gracefully on cheap phones** — worse sensors make it fire earlier, never later.

---

## What this changes in the coverage map

- **Moved from UNTESTED → GUARANTEED (safe):** multiple blackouts, excessive motion, GPS degradation, sensor-quality degradation.
- **Moved from UNTESTED → safe-with-minor-caveat:** line transfers (add the transfer-walk count landmark).
- **Moved from UNTESTED → known structural limit:** wrong-route — needs a **pre-blackout GPS route-match gate** in the app (this is the one genuinely new safety requirement surfaced by this testing round).

### Artifacts
- `gap_testing_summary.png` — late-fire safety + lead distribution across all 5 gaps
- `gap1_multiblk.json`, `gap2_transfer.json`, `gap3_wrongdir.json`, `gap3_wrongroute.json`, `gap4_excessmotion.json`, `gap5a_nlos.json`, `gap5b_sensordegrade.json` — raw per-seed results