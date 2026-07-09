# WakePoint — Synthesizer Fidelity Checklist

*Triage of the real-world-fidelity review. Status of each gap, with corrections where the original claim didn't survive verification. For a 1D-progress EKF `[s, v, b]`.*

## Verified before accepting

**Gradient drift magnitude — CORRECTED.** The review's "≈3.8 km drift over the 388 s tunnel" is worst-case-unmitigated and overstated. A 3° fully-mistracked grade = 0.51 m/s² apparent forward accel; sustained over 120 s that implies a 61 m/s velocity error — physically absurd, caught by ZUPT/GPS-speed long before. Correct framing: on a *sustained constant-speed* grade the complementary TiltFilter reconverges (DC accel = gravity); the damaging error is the **transient** at ramp entry/exit and when accelerating on the grade. Gradient is Tier-1 because it is the **untested underground input that could** cause large drift — the amount is a hypothesis Stage C measures, not a proven 3.8 km.

**Chirp frequency — CONFIRMED and sharpened.** Rail-joint pass frequency = v / joint-spacing = **0.3–1.5 Hz** at metro speeds, sweeping with speed. Implemented chirp validated: dominant frequency tracks speed r≈0.8 (0.9 Hz at 5 m/s → 3 Hz at 18 m/s), 12.7× quieter at dwells. Fixed 4 Hz was wrong in both frequency and constancy.

## Status table

| # | Item | Tier (mine) | Status | Note |
|---|---|---|---|---|
| 12 | **Reference-σ propagation** | **GATE #1** | spec'd for Stage C | Ranked above synthesizer items — nothing underground is interpretable without it. |
| 3 | **Background throttling** | **GATE** | ✅ done (axis K) | foreground/doze/throttled; `apply_throttle` + throttle_axis.json. |
| 2 | **Speed-tracking chirp** | **GATE** (promoted) | ✅ done | `carry_vibration_chirp`; gates MotionClassifier. Promoted from review's Tier-2. |
| 1 | **Track gradient** | **GATE** (magnitude reframed) | ✅ done (axis J) | `track_gradient`; ramps at tunnel entry/exit. |
| 6 | GPS multipath as bias + overconfident accuracy | Refine | queued | Sharpest Tier-2 — the combo that makes a filter trust a bad fix. |
| 8 | Post-tunnel reacquisition transient | Refine | queued | Gates whether scenario E9 means anything. |
| 4 | Curve cant / superelevation / easement | Refine | queued | Banking absorbs part of v²κ; phone sees residual. |
| 7 | Motion-coupled, cross-axis, non-Gaussian noise | Refine | queued | Couple vibration amplitude to \|a_tan\|. |
| 10 | Non-metro legs (escalator/stairs/turnstile) | Scenario axis | queued | Real ZUPT-trigger risk; currently near-absent. |
| 5 | Gyro g-sensitivity / scale / misalignment | **Lower** (demoted) | deferred | For a 1D-progress filter, bites only via TiltFilter/MotionClassifier — low yield. Review had Tier-2; I do it last. |
| 9 | Temperature-correlated bias drift | Lower | deferred | Time-correlated, double-integrates; small over 100 min. |
| 11 | Timestamp semantics / clock skew / batching | Lower | partial | 57 Hz gyro jitter already modeled; batching covered by throttle axis. |
| 13 | META: everything calibrated to n=1 | Not a code fix | ongoing | Every fitted distribution is a point estimate → **extrapolation flags = capture priorities for rides #2..#N**. |

## Ranking rule for the queued refinements
Add them **guided by the realism gate's MMD / C2ST**, not speculatively — implement, measure whether the two-sample distance to the real ride drops, keep what moves the needle. This prevents tuning many layers to a single ride.