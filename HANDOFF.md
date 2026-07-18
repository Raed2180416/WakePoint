# GeoWake — Engineering & Product Handoff

_Last updated: 2026-07-15. Written for the next agent/engineer picking this up cold._

App name is **GeoWake** (never "geowake2"/"WakePoint" in user-facing strings). Flutter, Android-first, India-first. Solo founder, budget-constrained. Repo dir is `WakePoint`; active work is on branch `sim-validation`.

---

## 0. THE ONE THING TO UNDERSTAND FIRST (read this before touching anything)

The product's job: **wake a transit rider before their stop, even when GPS dies underground.** For a year the assumed mechanism was a Kalman filter (EKF) that *dead-reckons position through the tunnel*. **That mechanism does not work on a consumer phone, and this is now measured, not assumed:**

- A handheld phone's accelerometer has ~**0.00 correlation** with actual train acceleration (attitude wobble leaks more gravity than the train's own accel). Confirmed on real rides.
- ZUPT / station-stop detection from IMU **fails** (accel, gyro, magnetometer all ~1× separation between moving and stopped, 14–44% missed stops). Confirmed.
- Pure dead-reckoning drift reaches **kilometres in minutes**; open-loop 20-min DR fires late ~30–55% of the time. Confirmed on real IMU vs real GPS.
- You **cannot prove** "never fire late" statistically — 2 rides give a 95% CI of [0%, 71%] on late-rate; certifying ≤0.1% needs ~3,000 independent tunnel windows. It's information-theoretically hopeless with collectable data.

**THE ACTUAL SOLUTION (this is the innovation, and it's provable):** a **reachability Protection Level**. When GPS is lost, the train *cannot* be further along than `last_known_position + max_line_speed × time_since_last_real_fix`. Fire when that worst-case reaches the target stop → **late-proof by physics, no sensors required, works on any metro.** Measured cost: fires 1–7 min early on short/medium blackouts (safe & usable), more on rare long ones (tightened by the stop-count cap below).

**Head-to-head, measured:** for the tunnel fire decision, the EKF's dead-reckoning adds **zero** value over reachability-only — reachability is both safe and tighter. So:

- The EKF is **demoted, not deleted.** Its real jobs remain necessary: (a) GPS-present tracking (~90% of every trip), (b) protecting the reachability anchor via phantom-fix rejection, (c) fire-decision plumbing. It just stops being trusted for the tunnel fire.
- Stop pouring effort into better drift models / ZUPT / magnetometer re-anchoring — all proven unreliable. They're optional Layer-1 tightening, never load-bearing.
- The pitch changes from "our Kalman filter dead-reckons through tunnels" (falls apart under scrutiny) to **"we use physics to guarantee we never let you miss your stop, even with zero signal"** (provable, honest, stronger).

Full evidence in `/home/raed/geowake_imu_analysis/`: `LONG_OUTAGE_ROBUSTNESS.md` (the reachability design + why never-late is unprovable statistically), `LONG_OUTAGE_VALIDATION.md`, `DRIFT_UNCERTAINTY_MODELING.md`, `GENERALIZE_ANY_METRO.md`, `MAGNETOMETER_STATION_SIGNAL.md`, `SYNTH_GENERATOR_DESIGN.md`, `DECONSTRUCTION_REPORT.md`, `WHAT_WE_NEED_TO_DO.md`.

---

## 1. GOAL: PRODUCTION-READY FOR INDIA

Priority order (do them in this order):

### P0 — the correctness core (this is the product)
1. **Build the reachability Protection Level.** Fire on `progress + max(clamped_σ_cushion, V_LINE × t_since_last_true_fix)`.
   - Wiring located: `lib/config/fire_decision_config.dart:41` (`maxFractileSigmaMeters = 300` — this clamp currently *causes* late fires; keep it for UX-tight firing but add a parallel **un-clamped** reachability cushion). `lib/services/alarm_evaluator.dart:~798–806` (add `reachCushion = V_LINE * t_since_last_true_fix`, use the `max`). Mirror on the ETA path (`alarm_evaluator.dart:~1496`, `alarm_controller.dart:~1476`).
   - New state: `t_since_last_true_fix` (wall-clock since last *accepted real* GPS fix, reset ONLY by a gate-passing fix — never by a snapped dwell), `s0_hi` (last true anchor + accuracy overbound), a per-line **`V_LINE` table** (default 28 m/s = 100 km/h; 39 m/s for express/airport lines).
   - **Stop-count topology cap** (tightens the early-firing): the train must pass each intermediate station, each with a min run-time — so `s_max(t)` is capped below `V_LINE·t`. Deterministic from the route fetch. This is the real UX lever, not the EKF.
   - **T_max watchdog:** if a blackout exceeds the budgeted time with no re-anchor, fire pre-emptively (waking early is the safe state).
   - **Three preconditions** the guarantee rests on — every possible late-fire is a violation of one: (i) anchor `s0` is a real fix not a phantom, (ii) `V_LINE` ≥ true max speed, (iii) `t` is wall-clock since last *true* fix. Test these explicitly.
2. **Merge the EKF fixes already landed on `sim-validation`** (commit `cfe52d8`): covariance-PSD-consistency guard (fixed a 518 km spike from a ZUPT-gain detonation), phantom-GPS rejection in `onGpsFixAuto`, velocity clamp in `_applyStateBounds`, dt>1s coast, cold-start bootstrap, **audible backstop channel** (`geowake_backstop_channel_v1` — the old backstop posted silently; MainActivity.kt + notification_service.dart). These are validated in the offline replay harness (`test/ekf/replay_harness_test.dart`).

### P1 — Android reliability (India device mix is the whole game)
3. **Survive Doze + OEM battery killers.** India = Xiaomi/MIUI-HyperOS, Realme, Vivo, Oppo, Samsung — all rated 5/5 on dontkillmyapp. You have `oem_autostart_service.dart` + a native wakelock/FGS plugin. Migrate to `flutter_foreground_task` v9.x with `foregroundServiceType='location'` (exempt from Android 15's 6h FGS cap). Pre-trip reliability check: `isIgnoringBatteryOptimizations()`, `canScheduleExactAlarms()`, `areNotificationsEnabled()` — block/warn before a critical commute on aggressive-OEM devices.
4. **The one test no simulation replaces: a real force-killed tunnel commute.** Ride the BLR Purple line, phone in pocket, screen off, battery-saver ON, force-kill the app mid-ride — does anything audible wake you? Do this before claiming "works."
5. **Play compliance:** targetSdk 35, 16KB page size, edge-to-edge. (build.gradle already at targetSdk 35, minSdk 24.)

### P1 — metro data (India)
6. **Fix the 9 flagged lines** (Delhi blue/magenta/orange/pink, Bengaluru '' + green, Ahmedabad yellow, Mumbai red, Nagpur orange) — NN-reconstructed ordering is untrustworthy. Use official GTFS (DMRC `otd.delhi.gov.in`, HMRL Hyderabad, KMRL Kochi). 37 confident lines are solid. Data ships in `assets/india_metro/` (19 cities, 805 stations).
7. **The route fetch already gives you the true track-distance-to-destination** (Google Directions leg distance + decoded polyline ≈ real arc-length; num_stops). That distance is the one input the reachability guarantee needs. It does NOT return intermediate stop names — cross-reference the shipped station sequence for "N stops away" UX.

### P1 — data you're missing
8. **Collect pocketed/asleep rides.** Every "it doesn't work" measurement was on *handheld* rides (the rider tapped stations, which handles the phone). The actual product scenario — phone stowed, rider asleep — is completely untested and might behave much better for stop-detection. This is the highest-value data collection. Needs an *independent* ground truth that doesn't touch the phone (a second phone logging, or GPS timing).

### Edge devices (be honest with users)
- No-gyro budget phones, no-barometer phones (none of our test phones had a barometer — worth adding to any future data collection). The `V_LINE` reachability guarantee is device-agnostic, which is exactly why it's robust to the cheap-phone long tail.

---

## 2. AD MONETISATION

Honest constraints: a wake-alarm is used **passively** (screen off, asleep) — there's almost no in-app attention to sell during the core flow, and India eCPMs are among the world's lowest (~$0.3–2 banners, ~$2–6 native). Ads alone won't sustain it; they're a floor, not the business.

**Where ads can live without wrecking UX:**
- **Route-arming screen** (before the trip) — native/banner while the user plans. Low intrusion.
- **Post-arrival screen** — the *best* ad moment: the user just woke, is at a real destination, and this is genuinely relevant ("You've arrived at Indiranagar — coffee/food/cab nearby"). This ties directly to the mobility-data asset (#4) and can be *native, location-relevant* rather than generic — much higher value.
- **Map/tracking screen** — a small banner during above-ground tracking.

**Never:** ads during the alarm, on the lock-screen wake, or anything that could delay/obscure the alarm. Reliability is the product; don't compromise it for a banner.

**Stack:** Google AdMob (best India fill) + mediation (Meta Audience Network, Unity). Rewarded video to unlock a premium feature for a day = decent India-friendly monetization (users trade attention not money). **The real ad upside is the post-arrival, location-aware placement** — that's a native-ads / local-commerce play, not generic banners, and it's the bridge to #4.

---

## 3. TELEMETRY / DIAGNOSTICS

This is **not optional** for a reliability-critical app — you cannot improve what you can't measure, and "did the alarm fire on time?" is the only metric that matters.

**Collect (aggregated, no PII):**
- **Alarm outcome funnel** — armed → tracking → GPS lost (duration) → fired {on-time / early / late / missed} → dismissed / snoozed. The north-star event is *"fired before the stop."*
- **Reliability funnel** — FGS survived vs OS-killed; Doze entered; backstop (exact-alarm) fired; permission states (location precise/approximate, notifications, exact-alarm, battery-opt-exempt). Break down **by device model + OEM + Android version** — this tells you which phones fail.
- **EKF/GPS health** — GPS-loss window durations, phantom-fix rejections, reachability-bound activations, drift at re-acquisition, cold-start events.
- **Crashes/ANRs.**

**Tooling:** Firebase Crashlytics + Analytics (free, fast) for crashes/funnels; consider **PostHog** (self-host, cheaper at scale, better product analytics) or Sentry. Keep raw ride traces **on-device** by default; upload only aggregated events + (opt-in) full traces for debugging.

**Key insight:** this telemetry *is* your Layer-1 self-improvement pipeline. The same ride traces that diagnose reliability also crowdsource each line's real speed profile / dwell / drift → tighten the per-line reachability early-firing. Design the telemetry schema so it doubles as the crowdsourced-calibration feed (see #4 for the privacy guardrails, which apply here too).

---

## 4. ANONYMISED MOBILITY DATA (my honest, detailed take — you asked for thoughts)

**The idea is commercially real.** "Where do people travel, when" is the location-intelligence industry (SafeGraph, Placer.ai, Veraset, Near). GeoWake is *uniquely* positioned because it knows **real transit destinations** (the stop you set), not just noisy GPS pings — that's higher-signal than most location data. Origin→destination transit flows are genuinely valuable to: transit authorities, urban planners, real-estate/retail siting, QSR chains (your restaurant example). This can be a real B2B revenue line.

**But it is also the single biggest risk to the whole company, and here's the unvarnished version:**

1. **"Anonymised" location data is a lie people tell themselves.** Human trajectories are near-unique — 4 spatio-temporal points re-identify 95% of individuals (de Montjoye 2013). Stripping names does *nothing*. A commute pattern (home→work, same time daily) IS an identity. So you cannot sell or even hold individual trajectories and call them anonymous.
2. **India's DPDP Act 2023 has real teeth.** Location is personal data. It requires **specific, informed, opt-in consent** for *each purpose* — you cannot repurpose alarm data for selling insights without a separate consent. Purpose limitation, the right to withdraw, and penalties up to **₹250 crore**. At scale you'll need a documented consent flow, likely a Data Protection Officer, and possibly Consent Manager integration.
3. **The trust math is asymmetric.** A wake-alarm app that knows when you sleep and where you commute, caught selling movement data, is a one-headline death. The intimacy of the data (sleep + commute) makes GeoWake *more* exposed than a generic maps app, not less.

**What is genuinely safe to collect and monetise (do it THIS way or not at all):**
- **Aggregate-only, never individual.** Report O-D flows at **station/zone granularity × hourly bins**, and *only* emit a cell when it has ≥ k users (k-anonymity, k≥50–100). Add **differential privacy** noise to counts. Sell *"~500 riders/day arrive at Indiranagar station 18:00–20:00"* — never a person, never a trajectory.
- **Explicit, separate opt-in consent** with plain-language explanation and easy withdrawal. Default OFF. The core alarm must work fully without it.
- **On-device aggregation / federated where possible** — compute the aggregate stats on the phone, upload only the aggregate, so raw trajectories never leave the device.
- **Transparency** — a real privacy policy, an in-app "what we collect / see & delete your data" screen. Make it a *feature* ("we protect your data"), not a liability.

**My recommendation on sequencing:** this is a **v2+ revenue stream, not a launch feature.** Do it *after* the core app has trust and scale — because (a) with few users the aggregates aren't valuable anyway (k-anonymity kills sparse cells), (b) you need the trust bank before you touch this, (c) it's a real engineering + legal project that would distract from getting the alarm right, which is the whole company. And start with the **cleaner buyer**: transit authorities / urban planners want aggregate O-D flows and it's far less creepy than micro-targeting a restaurant's customers. The restaurant-siting play is real but comes later, once you have defensible aggregation.

**What else is safe to collect (for the app itself, lower risk):** popular routes/times to power the app's own recents/suggestions; station congestion patterns; anonymous transit-mode splits. **Avoid entirely:** precise home/work coordinates as stored fields, individual trajectories, anything inferring health/religion/sensitive attributes, selling to data brokers.

**Bottom line:** yes, it's valuable and you're well-positioned — but treat it as a separate, consented, aggregate-only product built *after* trust, not as a way to monetise the alarm data you already have. Done right it's a moat; done wrong it's the end.

---

## 5. PREMIUM FEATURES

India willingness-to-pay is low (1–3% conversion, ₹49–99/mo or ₹299–499/yr; Indians prefer **one-time unlocks** over subscriptions). **Never paywall reliability or safety** — the alarm working is the trust foundation and the free tier's whole point.

Freemium split:
- **Free:** core alarm, 1 active route, ads, basic reliability. Enough to build trust + scale (which you need for #4 anyway).
- **Premium (convenience + polish):**
  - Ad-free.
  - Multiple / recurring / scheduled alarms; saved & frequent routes (the recents/frequency system is already built — `RouteMemoryService`).
  - Multi-leg journeys with interchange alerts; "wake me N stops / N minutes before" fine control.
  - Custom alarm sounds, escalating vibration, gentle-wake.
  - Offline metro maps + all cities.
  - Home-screen widget, Wear OS / watch alarm.
  - Family/shared alarms (wake a companion).
  - Priority/enhanced reliability *setup help* (not the reliability itself).

Pricing: lead with a **one-time "Pro" unlock** (~₹299–499) for India, offer a cheap annual too. Rewarded-ad "premium for a day" for price-sensitive users. Consider a founder/early-bird lifetime deal to bootstrap.

---

## 6. iOS

**The honest reality:** iOS is *more* restrictive for background execution than Android — no foreground-service equivalent, apps get suspended, continuous background location is limited. The Android reliability model (FGS + wakelock + exact alarms) does **not** port.

**But the reachability reframe makes iOS *more* feasible, not less** — because you no longer need continuous background dead-reckoning. You need a **time/place-based fire you can pre-compute:**
- **Region monitoring (geofencing) the destination station** — iOS wakes a suspended app on region entry, in the background, reliably. Geofence the destination (and a "N stops before" ring). This is the strongest iOS primitive and it fits GeoWake perfectly.
- **Scheduled local notification as the backstop** — since reachability lets you compute the *earliest possible arrival time* deterministically (route distance ÷ V_LINE), schedule a `UNNotificationRequest` for that time. iOS honours scheduled local notifications even when the app is suspended. This is the iOS analogue of the Android exact-alarm backstop.
- **`allowsBackgroundLocationUpdates` + significant-location-change** to keep a coarse position when moving, and to re-arm geofences.

**Concrete iOS work:** enable CoreLocation `Always` + background modes; `CLLocationManager` region monitoring for destination + pre-stop ring; `UNUserNotificationCenter` scheduled backstop from the reachability time; Live Activity (Dynamic Island) for the "N stops away" progress (nice-to-have). Flutter is already cross-platform; the deferred-iOS-rides issue earlier was a *data-analysis* artifact (gravity reconstruction), not a product blocker.

**Sequencing:** Android-first is correct (your market, and where reliability is hardest-won). Do iOS after the Android reachability core is proven on-device. iOS will actually be *cleaner* to make never-late once the reachability-time + geofence approach replaces the DR ambition.

---

## APPENDIX — WHERE EVERYTHING IS

- **Active branch:** `sim-validation` (off `android-reliability-hardening`). EKF fixes committed at `cfe52d8`.
- **Offline replay harness:** `test/ekf/replay_harness_test.dart` — drives the REAL EkfOrchestrator + AlarmEvaluator over real ride fixtures; never-late gate. Run: `PATH=~/flutter/bin:$PATH flutter test test/ekf/replay_harness_test.dart`.
- **Analysis + reports + data:** `/home/raed/geowake_imu_analysis/` — all the `*.md` reports, the real ride data (`extracted/`, `fixtures/`, `ground_truth/`), the ground-truth + synthetic-fixture generators (`build_ground_truth.py`, `build_fixture.py`, `build_synthetic_fixture.py`), the reachability/combo test scripts.
- **Real ride corpus:** 18 Sensor-Logger rides, 7 phone models (iOS+Android), Bengaluru. 2 clean Oppo Purple rides are the validated ones. iOS/interchange rides deferred (gravity reconstruction unreliable).
- **Google Maps key:** stored at `/home/raed/geowake_imu_analysis/.mapskey` (RESTRICT/ROTATE it — it's in the chat transcript). Directions gives route distance + stops.
- **Metro data:** `assets/india_metro/` — 19 cities, 805 stations, 37 confident + 9 flagged lines.

### The reframe in one line for whoever comes next
**Never-late is guaranteed by physics (reachability), not by dead-reckoning. The EKF handles GPS-present tracking and protects the anchor; it is not trusted in the tunnel. Build the reachability Protection Level first — it's the whole product, it's provable, and it works on any metro.**
