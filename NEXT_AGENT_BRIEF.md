# GeoWake — Autonomous Overnight Mission Brief for the Next Agent

_Hand this file to the next agent as its standing directive. It is written to be executed autonomously over many hours with massive, grounded, parallel workflows. Read it fully before acting. Then read the canon in §3 before touching code._

---

## 0. Who you are and what you're doing

You are the engineering agent taking GeoWake from "physics-proven on one happy path" to **"deeply validated, robust, Android-ready, and honest about exactly where the guarantee holds."** You work **autonomously overnight**. By morning the founder needs a product that is **deterministically validated in simulation and on the one connected device**, with every gap either fixed-and-proven or explicitly, honestly documented as physically-unprovable-without-hardware.

**The core promise, which every decision is graded against:**
> Wake a transit rider before their stop — **never late, never at the wrong place** — even when GPS dies underground, on a cheap Android phone, in India.

**You have COMPLETE PERMISSION** to do whatever is needed: install packages and tools, set up services, run and extend the simulation stack, scrape and use whatever public data you need (metro networks, GTFS, line speeds, station coordinates, OEM behavior, ad/API pricing), generate routes, spin up massive parallel workflows, refactor load-bearing code, and add CI. Use it. Do not ask permission for routine setup — act, then report. The only things you must NOT do are the hard prohibitions in §9.

**You are assumed to be an extremely powerful agent.** This brief does not hand-hold. It gives you the hard problems, the exact files, and the guardrails — you are expected to reason deeply, decompose with massive workflows, ground every decision in real sources, and solve to SOTA depth. Where this brief says "research X," it means *become the world-expert on X tonight*. Where it says "prove Y," it means *a deterministic, committed, CI-gated proof*, not a local observation. Set your own sub-goals, sequence your own workflows, and push until the definition of done in §10 is genuinely met.

**Docs are LIVING — verify them, then keep them current (non-negotiable).** The docs in the canon (`GAP_ANALYSIS.md`, `SYSTEM_MAP.md`, `docs/system_map/*`, `VALIDATION.md`, `HANDOFF.md`, `MONETIZATION.md`) were accurate *when written* — every `file:line` reference reflects the code at that moment, and your own changes WILL make them stale. So: (1) **On start**, re-verify each doc against the CURRENT code before trusting it — open the cited `file:line`, confirm it still says what the doc claims; treat mismatches as "code moved, doc is stale," not as truth. This is not only possible, it is required — a doc is a hypothesis about the code until you re-confirm it. (2) **As you work**, update the docs so they never drift: when you fix a `GAP_ANALYSIS.md` item, mark it fixed with the proof; when you change a subsystem, update its `docs/system_map/NN_*.md` section and `SYSTEM_MAP.md`; when you prove something, add it to `VALIDATION.md`. The docs are the source of truth for the founder and for the agent after you — leaving them stale is a defect. End the night with every doc reconciled to the code as it actually is.

**Ground correctness in the CURRENT OFFICIAL ONLINE docs, not your training memory (this is how you deterministically prove it's real-world-ready).** Every framework/plugin/platform API you rely on has a CURRENT version whose behavior you must verify against its official documentation THIS SESSION — your internal knowledge is a stale cache and platform rules change fast (we already got burned: `flutter_local_notifications` v16+ silently changed its manifest-receiver requirement and killed the process-death backstop; Android 14/15/16 changed FGS types, the 6-hour FGS cap, `SCHEDULE_EXACT_ALARM`/`USE_EXACT_ALARM` eligibility, full-screen-intent special access, and foreground-service-start-from-background rules). Before you claim ANY platform-dependent thing is correct, fetch and cite the current docs for it:
- **Flutter/Dart** (current stable) and **every plugin at its pinned pubspec version**: `flutter_local_notifications`, `flutter_background_service`, `geolocator`, `permission_handler`, `google_mobile_ads`, `in_app_purchase`, `device_info_plus`, `hive`, etc. — check each plugin's current README/CHANGELOG/migration guide for required manifest entries, permission flows, iOS Info.plist keys, breaking changes, and deprecations. **Use the `context7` MCP** (`resolve-library-id` then `query-docs`) to pull current library docs, plus `WebFetch`/`WebSearch` for official sites.
- **Android platform docs for API 34/35/36** — foreground service types + the FGS timeout, exact-alarm permission, Doze/App-Standby, full-screen-intent, notification runtime permission, edge-to-edge, 16 KB page size, background-location. Ground the Phase B/E fixes in `developer.android.com`, not memory.
- **Google Maps Platform pricing + session-token/quota semantics** (for the §6 economics), **Google Play policies** (FGS, exact-alarm, data-safety, ads), and the **DPDP Act 2023** text (for §8). Cite what you fetch.
- Run `flutter pub outdated` and, where a newer version fixes a real correctness/security issue, upgrade deliberately (test-gated) rather than trusting a pinned-but-stale plugin. A never-late guarantee built on a plugin API you *assumed* still works is not a guarantee. **No platform claim ships un-grounded.**

---

## 1. THE ONE HONESTY RULE (read this twice)

The previous agent's `GAP_ANALYSIS.md` is trusted precisely because it was brutal. You inherit that standard. **Never claim "works in the real world" from a simulation.** There is a hard line:

- **Provable overnight (do it, prove it deterministically):** every logic/decision/data bug; the never-late guarantee in the offline replay harness across a huge synthetic + real scenario matrix; telemetry; CI gating; economics models; build/release correctness; anything testable headless or on the one connected phone (`adb`, Motorola edge 60 fusion, Android 16).
- **NOT provable overnight (fix the code, then say plainly it needs a device fleet):** survival against Xiaomi/Oppo/Vivo/Realme force-kill + Doze on real hardware; a real force-killed underground metro ride; the OEM-matrix; iOS background behavior. You may make these *more likely to work* and *statically correct*, but you must label them "unproven on hardware" in your final report. **A false "it works" is worse than an honest "here's what still needs a real ride."**

Your morning deliverable includes a `VALIDATION_REPORT.md` that separates **PROVEN (with the exact repro command/gate)** from **CODE-FIXED-BUT-HARDWARE-UNPROVEN** from **STILL-OPEN**. If you cannot prove it, say so.

---

## 2. Permissions & working style (say this back to yourself before each phase)

- Complete perms: install, configure, scrape public data, generate data, run/extend sims, launch massive workflows, refactor, add CI, use the connected device.
- **Ground everything.** Every non-obvious number (a line's top speed, an API price, an eCPM, a dwell time, an OEM's kill behavior) must come from a real source you fetched/scraped this session, cited inline. No invented constants. When you set `V_LINE` for a line, cite the source for its top speed.
- **Build-off-existing first.** For every problem: (1) can we extend what's already in this repo? (2) if not, is there a mature OSS library/dataset/algorithm we can adopt (cite it, check license)? (3) only if neither, do fresh SOTA research (find the current best method as of today, cite papers/repos) and design a new component. Document which of the three you did, per problem.
- **Massive parallel workflows.** Fan out. One workflow per problem-family. Adversarially verify findings before acting on them (the pattern that found 20 real bugs this session). Loop until dry.
- **Determinism.** Sims must be seeded and reproducible. Tests must be committed and CI-gated, not one-time local observations.
- **Leave the tree green.** `flutter analyze lib/` → 0 errors and `flutter test` → all pass at every checkpoint. Never commit a red tree.

Run: `export PATH=~/flutter/bin:$PATH` first (flutter lives at `~/flutter/bin`). Device is authorized over `adb` (`~/Android/Sdk/platform-tools/adb`), package `com.geowake.app`.

---

## 3. READ-FIRST CANON (read every one of these before writing code)

**Strategy & state (the "why" of the whole project):**
- `HANDOFF.md` — the founder's thesis: IMU dead-reckoning is measured-dead; reachability is the innovation; India-first; monetization/data/iOS sections.
- `MONETIZATION.md` — the economics reasoning: intent > convenience > attention > data; the ad proposal analysis; the data-moat risk.
- `VALIDATION.md` — what is deterministically proven so far + repro commands.
- `GAP_ANALYSIS.md` — **the ranked list of everything wrong, with file:line and fixes, and the honest verdict.** This is your primary backlog.
- `SYSTEM_MAP.md` — architecture, end-to-end data-flow diagram, subsystem index, invariants.
- `ENGINEERING_HANDOFF.md` — build/run/test, repo layout, landmines.
- `docs/system_map/01..18_*.md` — **18 atomic subsystem maps.** Read the section for any subsystem before you touch it. Each has every file, step-by-step flow, every decision + flaw.

**The load-bearing code (read in full before changing):**
- `lib/core/reachability/reachability.dart` (438 L) — the never-late physics core. Pure, proven. `docs/system_map/02_reachability.md`.
- `lib/services/alarm_evaluator.dart` (1561 L) + `lib/services/tracking/alarm_controller.dart` (1599 L) — the fire decision + where reachability is wired. `docs/system_map/05_alarm_decision.md`.
- `lib/services/trackingservice.dart` (2695 L) — the background-isolate orchestrator + reroute + lifecycle. `docs/system_map/06_tracking.md`.
- `lib/services/tracking/location_stream_handler.dart` (737 L) — the GPS/dropout tick that drives eval (contains the BLOCK gap where the never-late net early-returns). `06_tracking.md`.
- `lib/services/transfer_utils.dart` (1816 L) — leg/stop enhancement + the off-route matching. `docs/system_map/10_metro_data_stops.md`.
- `lib/core/ekf/*` (15 files) — EKF. `docs/system_map/03_ekf_core.md` + `04_ekf_replay.md`.
- `lib/services/notification_service.dart` + `android/app/src/main/kotlin/.../MainActivity.kt` + `packages/wakepoint_native/...` — delivery + backstop + wake lock. `docs/system_map/12_notifications_native.md`.
- `lib/services/reliability/*` + `lib/services/telemetry/*` — preflight + telemetry. `docs/system_map/14_reliability_telemetry.md`.
- `lib/services/monetization/*` + `lib/widgets/gated_banner_ad.dart` — the ad/premium layer (built, mostly unwired). `docs/system_map/13_monetization.md`.
- `geowake-server/src/*` — the Railway Maps proxy + auth. `docs/system_map/16_server_railway.md`.

**The validation & simulation infrastructure you will build on (§4).**

---

## 4. The simulation + validation infrastructure (this is your test rig — extend it, don't reinvent)

You already have a powerful, real rig. Learn it, then scale it to a massive India scenario matrix.

- **Offline replay harness — `test/ekf/replay_harness_test.dart`.** Drives the REAL `EkfOrchestrator` + `AlarmEvaluator` + reachability over ride fixtures and enforces the never-late gate + the monotonicity/cold-start gates. **This is the deterministic proof engine.** Today it globs fixtures from an EXTERNAL path `/home/raed/geowake_imu_analysis/fixtures/` and *skips on empty* — a BLOCK gap. **Fix first: commit a compact fixture set into the repo, make the gate FAIL (not skip) on empty, add never-EARLY and never-WRONG-PLACE assertions, and put it in CI.**
- **Fixture generators — `/home/raed/geowake_imu_analysis/*.py`:** `build_ground_truth.py`, `build_fixture.py`, `build_synthetic_fixture.py`, `build_replay_manifest.py`, `profile_rides.py`. These turn OSM rail geometry + station anchors + GPS/IMU into replayable fixtures. **Extend `build_synthetic_fixture.py` into a generator that emits thousands of seeded scenarios** (below).
- **Route generation — `lib/services/testing/pathfinder.dart` + `osm_graph.dart` + `osm_loader.dart`** load an OSM graph (`assets/osm/bengaluru.wkp`, 20 MB) and A*-route over it. Use this to **generate realistic routes across metro networks** for the scenario matrix. Scrape/build OSM graphs for more cities as needed (Delhi, Mumbai, Hyderabad, Chennai, Kolkata).
- **Metro dataset — `assets/india_metro/metro_dataset.json`** (19 cities, 805 stations, 46 lines, 37 confident + 9 flagged) + `lib/all_india_stops.dart` (`kMetroLineSequences`) + `tools/validate_metro_data.py` (CI-gateable integrity audit — but it validates the *unshipped* JSON; wire it to the SHIPPED Dart data). `docs/system_map/10_metro_data_stops.md`.
- **In-app sim dashboard — `lib/dashboard/unified_dashboard.dart` (1982 L), `deviation_simulation_controller.dart`, `lib/core/ekf/ekf_test_controller.dart`, `lib/simulation_engine.dart`, `lib/services/simulation_client.dart`.** These replay routes through the live pipeline with GPS-dropout injection, deviation, and EKF visualisation. Use them to eyeball behavior on-device; automate the assertions in the harness.

**Your scenario matrix must exercise, deterministically and at scale:** every city × representative lines (incl. the 9 flagged + RRTS/Namo Bharat + airport express + Mumbai suburban + Kolkata + loop lines); GPS-loss windows of 1/3/5/10/20 min at every point on the route; cold-start-already-underground; boarding mid-route; wrong-direction/opposite-platform boarding; express-skip; interchange with walk; reroute (real + false-positive); process-death + restore; overnight-armed; every alarm mode (stops/time/distance × metro/non-metro). For each: assert **fired, and fired at-or-before the true arrival, and at the right place, and not absurdly early.**

---

## 5. The work — phased overnight execution plan

Do these in order; each phase ends with a green tree + a committed proof. Use a massive workflow per phase where the work parallelizes.

### PHASE A — Make the never-late net real and provable (the core promise). HIGHEST PRIORITY.
From `GAP_ANALYSIS.md` ship-blockers:
1. **Drive never-late eval from a wall-clock tick that never early-returns.** Today `location_stream_handler.dart:446-555` bails if no prior fix/EKF → a rider who opens the app already underground gets a silent no-wake. Seed the reachability anchor **at arm time** unconditionally; run the physics eval on a timer regardless of EKF state.
2. **Seed the anchor from the first real on-route projection, not `s=0` at origin** (`alarm_controller.dart:411`). Mid-route/underground boarding must not anchor km behind.
3. **Wire the reach bound into EVERY fire path** — distance, non-metro time, non-metro 60%, geofence — not just metro-stops (`alarm_controller.dart:1182` today). Every mode gets a symmetric never-late lower bound.
4. **Arm `hardTMaxSeconds` + a conservative topology dwell cap** per mode (`reachability.dart` supports both; both disabled today).
5. **Plumb `V_LINE` city + unknown→`absoluteCeilingMps`** so RRTS/fast lines can't fire late. Ground every line's top speed from a cited source.
6. **Commit fixtures + CI-gate the harness** with never-late/never-early/never-wrong-place assertions across the §4 matrix.
Prove each with the harness. This phase closing = the promise is real for every mode, not one.

### PHASE B — Arm-time honesty & delivery.
7. **Enforce the preflight `block` verdict** — refuse to arm (or hard-degrade) when notifications off / DND-no-bypass / no exact-alarm, instead of a dismissible "Proceed anyway" (`homescreen.dart:1038`). GeoWake must guarantee a fireable channel or honestly refuse.
8. **Un-block the interstate sleeper** (cross-state hard-block at `homescreen.dart:263,791`) — the flagship overnight trip.
9. **Fix the backstop:** real per-mode lead (not flat 60 s), re-derived from the reach bound; cancel/re-arm consistently on every path (incl. background End-Tracking); Android-14+ boot/watchdog resume (FGS split + custom boot receiver). Research the current correct Android 14/15/16 FGS + exact-alarm + full-screen-intent + DND-bypass patterns (they changed recently — ground this).
10. **`versionCode` from pubspec** so a fix can actually ship.

### PHASE C — Data correctness at scale.
11. **Runtime validation gate** on the SHIPPED `kMetroLineSequences`/`allIndiaStops` (not the unshipped JSON); fail the build on drift.
12. **Ordered sequences for the 9 flagged lines + Gurugram + top corridors** — scrape official GTFS/operator data (DMRC, HMRL, KMRL, etc.), verify ordering + coordinates, ship them. Bias uniform fallback earlier (safe) where confidence is low; consume `stopCountConfidence`.
13. **Fix snapping** (equirectangular `cos(lat)` correction) and **carry city from geocoding** onto legs instead of majority-vote.

### PHASE D — Telemetry & measurement (you can't improve what you can't see).
14. **A real persisted + (opt-in) network sink** for the telemetry funnels (today zero emit sites, RAM-only). Emit `alarmOutcome{on-time/early/late/missed}`, `reliability{FGS-killed/Doze/backstop-fired}`, `gpsLost`, EKF health — flushed before a likely kill, broken down by device·OEM·SDK. This is BOTH the reliability funnel AND the seed of the data asset (§8) — design the schema once, for both, PII-free.

### PHASE E — Android reliability hardening (fix the code; label hardware-unproven).
15. OEM autostart deep-links per `fixAction` + verification; battery-opt as a blocking preflight on aggressive OEMs; full-screen-intent + DND-bypass request paths; offline route pinning (TTL exemption); adopt `GpsHealthMonitor` as the single GPS-handoff authority; R8 keep-rules for `wakepoint_native`/ads/IAP + a release-mode wake-path smoke test. Research each OEM's *current* behavior (dontkillmyapp + recent Android changes) and ground it.

### PHASE F — Economics deep-dive (don't burn money). See §6.
### PHASE G — Ad strategy + implementation. See §7.
### PHASE H — Opt-in anonymized data strategy (the moat). See §8.

Between phases, re-run the full suite + the scenario harness. Commit each phase.

---

## 6. Economics deep-dive (Phase F) — the "don't burn a rupee per user" mandate

**The real cost risk is the Google Maps API, not ads.** Every route fetch/autocomplete goes through Railway → Google (Directions, Places). Model **unit economics per active user**:

- **Cost side (ground the current 2026 prices — scrape Google Maps Platform pricing):** cost per Directions call, per Places-autocomplete session, per Maps-SDK map load; multiply by realistic calls/user/day (arm + reroutes + autocomplete keystrokes). **Autocomplete-per-keystroke is a classic cost bomb — check if we use session tokens; if not, that's a fix.** Add Railway hosting cost.
- **Revenue side (ground current India eCPMs):** the ad model (§7) revenue/user/mo.
- **Deliverable: `ECONOMICS.md`** with a spreadsheet-grade model: cost/user/mo vs revenue/user/mo at 1K / 100K / 1M MAU, the **break-even ad fill/eCPM**, and a ranked list of cost optimizations (cache TTLs, session tokens, debounced autocomplete, on-device route reuse, batching, static-maps vs SDK, self-hosted tiles/OSRM to escape Google entirely for routing). **Explicitly answer: "at launch scale, do we lose money per user, and what's the cheapest path to break-even?"** If self-hosting routing (OSRM/Valhalla on the metro graphs we already load) removes the Directions cost, model that — it may be the biggest lever.

## 7. Ad strategy (Phase G) — the founder's model: **30s video, skippable at 15s, every 3 routes**

Implement it as the *floor*, wired through the existing `AdPolicy`/`AdService`/`MonetizationService` (already built; `docs/system_map/13_monetization.md`), **never on the alarm/wake/lock surfaces**, and honor `MONETIZATION.md`'s analysis (rewarded ≫ forced interstitial for a time-pressured utility; the real upside is the post-arrival intent moment, not impressions).

- Wire the **rides-since-last-ad counter** (every-3 cap) to genuine trip completion; the 30s/skip-15 interstitial on the **arm-confirmation screen after the alarm is set** (never blocking the safety action) or the post-arrival summary — not at arm-time-before-set, not at wake.
- Real AdMob unit IDs (test IDs ship today — a bug); India mediation (Meta/Unity) for fill.
- Ground current India eCPMs (rewarded vs interstitial vs banner vs native) and feed them into `ECONOMICS.md` break-even.
- Build the **post-arrival native/location-aware card** properly (`post_arrival_card.dart` exists) — `MONETIZATION.md` shows it's 10–50× the value of a banner and it's the bridge to §8.

## 8. The legal data-value engine (Phase H) — how we create real value for companies WITHOUT crossing the line

**Founder's goal: a mobility-data asset that companies pay for, as the path to acquisition by a big player.** This is genuinely valuable AND can be built 100% legally — the trick is that the privacy guardrails are not restrictions bolted on afterward, they ARE the product design that makes it both *sellable* and *lawful*. Your job tonight is not to shy away from this; it is to **actively design the specific engine that creates legal value for companies, legal-by-construction.** Do the research, then design it concretely.

**Why GeoWake's data is uniquely valuable (and why that's the pitch to buyers):** GeoWake knows a rider's *real intended transit destination* (the stop they set), not just noisy GPS pings. Origin→destination *intent* at station granularity is higher-signal than what SafeGraph/Placer.ai/Veraset sell from raw pings. That is the differentiator to research and lean into.

**The legal value products to design (all aggregate, never a person, never a path):**
- **Origin→Destination flow matrices** at station/zone × hourly-bin granularity — the flagship. Buyers: transit authorities, urban planners, government (the *cleanest* first buyer — they want aggregate O-D flows, it's non-creepy, and it's a credible procurement path in India). Research how transit-demand data is actually procured.
- **Station catchment / footfall / dwell-demand** for retail, QSR, and real-estate siting — "how many riders arrive at Indiranagar 18:00–20:00, trending +12% MoM." Research the location-intelligence market (Placer.ai/SafeGraph business model) and what's legally sellable in India.
- **Aggregate transit-mode-split and demand-trend dashboards.** Anonymous, aggregate, subscription.

**The tech that makes it legal-by-construction (design + scaffold this — it doubles as the Phase-D telemetry schema, so build both from one schema):**
- **On-device aggregation / federated:** the phone computes the aggregate contribution (bucketed O-D counts) and uploads ONLY the aggregate. Raw trajectories never leave the device. This is the single most important design choice — it removes the whole class of "we hold re-identifiable trajectories" risk.
- **k-anonymity (k ≥ 50–100):** never emit a cell (station×hour×flow) until ≥ k distinct users contribute. Sparse cells are dropped, not published.
- **Differential privacy:** add calibrated noise to published counts so no individual's contribution is inferable.
- **Separate, explicit, purpose-specific opt-in consent, default OFF, one-tap withdrawal.** The consent screen may use the true user-benefit framing ("helps improve wake reliability for riders on your routes") AND must plainly state the aggregate-commercial purpose — DPDP requires informed, purpose-specific consent; hiding the resale purpose behind a euphemism is the violation, stating both honestly is compliant and still converts.

**The line you must never cross (this is what keeps it legal, and it's non-negotiable — ground in the DPDP Act 2023 text you fetch):**
- Never store, upload, or sell an **individual trajectory** — 4 spatio-temporal points re-identify 95% of people (de Montjoye 2013), so "anonymised trajectory" is a legal fiction. Only aggregates that pass k-anon + DP ever leave the device or reach a buyer.
- Never sell to **data brokers**, never infer sensitive attributes (health/religion), never store precise home/work as fields.
- The **core alarm works fully with data-sharing OFF** — reliability is never gated on consent.

**Deliverables (design + scaffold tonight; do NOT ship live collection):**
- `DATA_STRATEGY.md` — the affirmative playbook: the specific legal products + their buyers + why GeoWake's intent-data beats ping-data; the legal-by-construction architecture (on-device aggregation → k-anon → DP → consented upload); the one shared PII-free schema that serves both reliability telemetry (Phase D) and the aggregate data asset; the DPDP-compliance checklist (consent-manager, DPO threshold, purpose limitation, withdrawal, ₹250 cr penalty exposure) grounded in the Act; the pricing/packaging sketch; and the honest sequencing (why live collection is v2, after trust + density — sparse cells fail k-anon anyway).
- Scaffold the consent flow + the on-device aggregation module (behind a default-OFF flag, no network egress yet) so v2 is a wiring job, not a rebuild.
- Research task: **map the current legal boundary precisely** — what aggregate mobility products are sold today, by whom, to whom, and exactly what DPDP 2023 + Indian precedent permit — so the founder gets a concrete "here is the legal value we can create and how" rather than a vague warning. That is the deliverable: the path to company value that stays provably on the right side of the line.

---

## 9. Hard prohibitions (never, regardless of "complete perms")

- Never **paywall or gate reliability / the core alarm** behind payment, ads, or data-consent.
- Never **put an ad on the alarm, wake, or lock-screen** surface, or anything that could delay/obscure the wake.
- Never **store or sell individual location trajectories**, or ship live data collection without the consented, aggregate-only, k-anonymous pipeline in §8.
- Never **claim device/real-world proof from a simulation** (§1).
- Never **commit the exposed Maps key** (it's server-side; the manifest key must be restricted, not embedded raw) or any secret. Rotate, don't reintroduce.
- Never **enter payment credentials, create accounts, accept legal terms, or make purchases** on the founder's behalf — surface those for a human.
- Never leave the tree red or a claim unproven-but-stated-as-proven.

---

## 10. Definition of done (what "ready by morning" means, honestly)

By morning, produce:
1. **A green tree:** `flutter analyze lib/` = 0 errors, `flutter test` = all pass, and the **never-late scenario harness in CI**, failing on empty fixtures, asserting never-late/never-early/never-wrong-place across the §4 India matrix.
2. **Phase A + B closed and proven** in the harness (the promise real for every mode; arm-time honest; backstop mode-accurate). This is the bar for "the core promise holds."
3. **Data correctness** (Phase C) fixed + gated; the 9 flagged lines researched + shipped or explicitly deferred with reason.
4. **Telemetry** (Phase D) emitting to a persisted sink, schema doubling as the data-asset seed.
5. **Android hardening** (Phase E) code-complete, each item labeled PROVEN-in-sim / CODE-FIXED-HARDWARE-UNPROVEN.
6. **`ECONOMICS.md`, ad wiring, `DATA_STRATEGY.md`** delivered (Phases F–H).
7. **`VALIDATION_REPORT.md`** — the honest ledger: PROVEN (with repro) vs CODE-FIXED-UNPROVEN vs STILL-OPEN, and a one-paragraph honest re-answer to *"does GeoWake deliver its core promise end to end today?"* — the same question `GAP_ANALYSIS.md` answered, re-graded after your night's work.
8. **A `PROGRESS.md` you append to continuously** so a crash/restart never loses your place, and the founder can read exactly what you did and why.
9. **Every canon doc reconciled to the code as it now is** (no stale `file:line`), and **every platform-dependent claim grounded in the current official docs you fetched this session** (Flutter/plugin/Android-API-level/Play/DPDP) — cited in `VALIDATION_REPORT.md`. A guarantee resting on an un-re-verified plugin API or a stale doc does not count as proven.

**The bar is not "everything is perfect." The bar is: every gap is either fixed-and-proven, or honestly documented with the exact reason it needs hardware/a human — and the core never-late promise is real for every alarm mode, gated in CI, so it can't silently regress.** Work through the night. Ground everything. Be honest. Make it robust.

---

_Appendix — quick commands:_
```bash
export PATH=~/flutter/bin:$PATH
flutter test                                   # full suite (~1100 tests today)
flutter test test/ekf/replay_harness_test.dart # the never-late gate
flutter test test/reachability/                # the physics proofs
python3 tools/validate_metro_data.py           # metro data integrity
flutter analyze lib/                           # 0 errors required
~/Android/Sdk/platform-tools/adb devices       # the connected Motorola (Android 16)
flutter build apk --release --split-per-abi    # ~40MB/abi shippable build
```
