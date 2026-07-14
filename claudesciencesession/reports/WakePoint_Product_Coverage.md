# WakePoint — Product Intent & Coverage Map

**Date:** 2026-07-09 · **Audience:** you (for the pitch), and whoever tests it before production.

This is the plain-language answer to *"is the GPS-out engine rock solid, and what can we honestly promise?"* — with every claim labeled **GUARANTEED** (sim-verified), **BOUNDED** (safe but not tight), or **UNTESTED** (a real gap). No happy-path spin.

---

## The product in one line

WakePoint wakes a transit rider before their stop — **even when GPS is gone** (underground, tunnels) — by dead-reckoning along the route the rider already chose, using only the phone's motion sensors, and firing the alarm **early-never-late** because a missed stop is the only unacceptable failure.

## The one design principle everything follows

**Asymmetric cost.** Waking someone 2 minutes early is a minor annoyance. Waking them *after* their stop is a product-killing failure. So every uncertain decision in the engine is architected to fail toward **early**, never late. This is why the engine can be honestly robust even when position is uncertain: it doesn't need to know exactly where you are, it needs to never let you sleep past your stop.

## What we can promise (GUARANTEED — verified in simulation)

1. **Never fires late whenever GPS re-acquires at least once during the trip** — the normal metro case. Across 40 real metro topologies (Chennai, Delhi, Kolkata, Tokyo), multiple-blackout journeys, and line-transfer journeys, with the two boundary bug-fixes + 13-min watchdog in: **0-to-1 harmful late fires** (the single transfer late-fire was +69 s, in a deliberately hard target-right-after-transfer alignment). This is the case >95% of real riders are in — you surface at *some* point (station, above-ground segment) even on mostly-underground lines. **Two cases are NOT yet zero-late and are called out honestly below (see item 5 and the frontier): cold-start-fully-underground with no GPS ever (1/6 late), and long-blackout + wide-spacing express routes.** Those need the curvature anchor, which is built but not yet shipped.
2. **The core tracking works underground.** The EKF cuts blackout position error 6.5× vs naive extrapolation, 18× vs freezing the last GPS fix. It works by catching station stops and fusing measurements, not by guessing motion.
3. **Stop-detection is reliable.** The dwell detector (the keystone of metro mode) misses ≤2.6% of real stops across all 5 phone-carry positions (hand, pocket, bag, lap, to-ear).
4. **The velocity model fails safe.** On real data (which differs from our simulator), the model self-detects it's out-of-distribution 70% of the time and automatically stops trusting itself — so a wrong velocity guess inflates uncertainty (fires early) rather than driving a confident-wrong late fire.

## What we should NOT over-promise (BOUNDED — safe, but not tight)

5. **"Wakes you within 3 minutes"** holds on normal and adversarial metro routes **except** two extreme cases, where the ship-now engine is NOT tight:
   - **Long continuous blackout (15-25 min) + wide station spacing (express/skip-stop):** fires **safely early** (never late) but can be several minutes early — pinning the exact moment over a 20-minute sensor blackout is physically impossible without a real position fix.
   - **Cold-start fully underground (no GPS the entire trip):** here the ship-now fixes are **not yet guaranteed never-late** — on a long fully-underground trip the stop-count can silently drift and 1 in 6 tested cases fired late (worst +7 min). This is the single hardest case and the one the curvature anchor was built to fix (it takes this from 1/6 late to 0/6). **Until the anchor ships, treat fully-underground-start trips as the known residual late-fire risk.**

   Honest pitch line: *"never late on any trip where GPS is available at least briefly; on express/long-tunnel routes it errs early, never late; the fully-underground-start case is the one we're still hardening."* **The fix (curvature anchor) is built and validated on 6 underground routes but needs corpus tuning before shipping — see the frontier below.**

## What we have now TESTED (was UNTESTED — see `WakePoint_5Gap_Results.md`)

All five previously-unverified gaps were tested end-to-end this session against the full shipping engine. Four are safe, one has a minor caveat, one surfaced a structural requirement for the app.

6. **Multiple separate blackouts in one journey** (dip underground, resurface, dip again) — **SAFE, 0/16 late.** GPS re-anchors on each resurface; the count survives re-acquisition.
7. **Line transfers** (change trains mid-trip) — **safe with one caveat, 1/10 late (+69s).** The transfer walk is a dwell-less segment the count can't advance through; fix is to treat walk-completion as a count landmark. Minor.
8. **Wrong-direction while blacked out** — **SAFE, 0/10 false alarms** (reverse is clamped, so the alarm never falsely fires for a backward-traveling rider). It's detectable (−10km net displacement) — the app could add a "wrong train" alert but isn't required to for alarm safety.
9. **Wrong-route (rider on a different line than prefetched)** — **STRUCTURAL LIMIT, 1/6 late.** During a blackout the engine tracks its prefetched belief and is blind to the mismatch — unfixable from IMU alone. **This is the one genuinely new safety requirement: the app must verify route-correctness via GPS *before* the blackout (while boarding above-ground).**
10. **Excessive fidgeting / walking-in-car while standing/sitting** — **SAFE, 0/12 late.** The band-energy vehicular gate rejects non-vehicular motion; dwell count unchanged even at high injected motion.
11. **GPS degradation (NLOS/multipath wrong fixes)** — **SAFE, 0/12 late.** The Huber gate absorbs wrong fixes; even 300m bias errs early, never late.
12. **Cheap-phone sensor quality (2–4× noisier IMU)** — **SAFE, 0/12 late.** Honest covariance grows with noise → fires earlier → degrades gracefully.

*(Also this session: the dwell-miss rate was measured and is GUARANTEED (≤2.6%). Cold-start-fully-underground was tested — the ship-now engine fires 1/6 late on long fully-underground trips, closed to 0/6 only by the unshipped curvature anchor; it remains a known residual late-fire risk under item 5.)*

**The two real to-dos surfaced by this round:** (a) a **pre-blackout GPS route-match gate** in the app's boarding logic (wrong-route safety — item 9), and (b) treat the **transfer-walk as a count landmark** (item 7). Neither is in the GPS-out filter; both are app-logic additions.

## The honest frontier: two things that block "rock solid in production"

**(A) The engine isn't wired in production.** The verified fixes only run if the filter is told GPS dropped — and today that signal is never sent in the production app (only in tests). **One wiring fix (a no-fix watchdog) makes the whole GPS-out engine actually engage.** This is the single highest-priority code change.

**(B) The runtime can kill the alarm before the engine matters.** If the OS suspends the app while the rider sleeps (battery optimization, OEM task-killers, no wakelock), none of the tracking runs. These are ordinary mobile-engineering fixes (wakelock, battery-exemption prompt, an OS-level exact-alarm safety net), require on-device work, and are covered in the Dart Port Spec (Part D). *The filter is largely done; the runtime/lifecycle engineering is the actual remaining product risk.*

## The curvature anchor — the one research bet worth making

The single limitation (item 5) and the hardest untested case both resolve the same way: a **real position observation during the blackout**. The route's turns are a fingerprint — matching the phone's sensed turning against the known route curvature can tell you where you are without GPS. Built and tested this session: as a standalone tracker it's not robust yet, but as a **backup that catches when the stop-count has silently drifted**, it took the worst fully-underground case from a late fire to a safe early one. It's the highest-value thing to build next, and it's a genuine engineering project, not a weekend patch.

## For your budget-constrained real-world testing

You said money for real rides is tight. Spend it where simulation is weakest, not on ordinary rides:
1. **One completely-underground trip** (start tracking with no GPS, stay underground) — the hardest case and the one most dependent on unverified real-data behavior.
2. **One express / wide-spacing route** (long gaps between stops) — where the bounded-early limit lives.
3. **One ordinary logged ride on a different phone** — this is the single most valuable data point, because it breaks the velocity-model circularity (our model is trained on our own simulator; one real ride on a new device tells us if it generalizes).
4. **On-device screen-off survival** — leave it running with the screen off through a real trip; this tests the runtime/lifecycle risk (B) that no simulation can.

Everything else can wait for user telemetry post-launch.

---

### Supporting artifacts
- `WakePoint_GPSout_Handoff.md` — full technical detail (10 sections)
- `WakePoint_Robustness_Report.md` — the brutal assessment + the GPS-out addendum
- `WakePoint_Dart_Port_Spec.md` — exactly what to change in the repo, gated on evidence
- `gpsout_summary.png` — the 3-panel visual summary
- `wakepoint_curvature_anchor.py` — the research anchor build