# GeoWake — Developer Handoff

Welcome. This folder is your **front door** to the GeoWake codebase. It exists so you can get productive fast, then **go discover things yourself** — it is a map, not a cage.

GeoWake is a **transit wake-alarm for Android** (Flutter). You pick a destination, arm an alarm, and the app wakes you before you get there — even if your phone is in your pocket, screen off, in a tunnel, for an hour. The whole engineering effort orbits one promise:

> **Never wake you *late*. Never wake you *too early*.**

Everything else — the map, the search, the EKF, the background service — exists to keep that promise on a real phone in the real world.

---

## Start here (read in this order)

| # | Doc | What it gives you |
|---|-----|-------------------|
| 1 | **[ENGINEERING_OVERVIEW.md](ENGINEERING_OVERVIEW.md)** | End-to-end explanation of how the app works — architecture, every subsystem in plain English, and the never-late guarantee explained intuitively. Read this first. |
| 2 | **[E2E_TEST_GUIDE.md](E2E_TEST_GUIDE.md)** | Every feature + exactly what to test end-to-end on a real device, the nasty edge cases, and which bugs are already known so you don't re-find them. This is your playground. |
| 3 | **[../testing/ISSUES.jsonl](../testing/ISSUES.jsonl)** | The findings log — ~196 issues (`GW-0001`..) with severity, evidence, repro. This is our shared memory of what's broken. **Append to it as you discover things.** |
| — | [../../SYSTEM_MAP.md](../../SYSTEM_MAP.md) | Auto-generated structural map of the code graph (files, call chains). Good for "where does X live." |

> The prior work leaned heavily on **simulation** (deterministic never-late proofs, EKF replay). The weak spot — and your biggest opportunity — is **real-device end-to-end testing**. The math is proven; the phone behavior is not. Own that gap.

---

## Repo state (as of this handoff)

- **Visibility:** the repo is now **private**. Ask Raed to add you as a collaborator.
- **Main branch:** `stable-release-1` (the default). Everything is unified here via a clean fast-forward — one branch, linear history, nothing stranded on side branches.
- **Findings:** `docs/testing/ISSUES.jsonl` — 196 entries. Schema is one JSON object per line: `{id, title, severity, front, evidence, repro, expected, actual, status, ...}`. Severities: `P0` (never-late/safety), `P1` (blocker), `P2-subpar`, `P3-nit`.

### ⚠️ Three things to know on day one
1. **Rotate the Google Maps API key.** A once-live key (`AIzaSy…XHw0`) was public in git history for ~12 days and is extractable from any APK. Rotate it in Google Cloud and restrict it to the Android app (package `com.geowake.app` + signing SHA-1) + Maps SDK only. Tracked as **GW-0158**.
2. **`flutter build apk --release` produces an *unsigned* APK.** No signing keystore is wired (`android/key.properties` only holds the Maps key). You must sign manually or wire a release `signingConfig`. Tracked as **GW-0196**.
3. **The "Wake Me!" button is disabled on a fresh launch** — typing a destination shows no autocomplete, so a first-time user can't complete the core task. This is the **highest-signal bug to chase first** (GW-0194 family / UX committee findings).

---

## 5-minute quickstart

```bash
flutter pub get

# DEBUG build — DO NOT ship or judge performance on this.
#   ~300 MB installed, runs Dart in JIT/interpreted mode = laggy, cold-start stalls.
flutter run                      # for development only

# RELEASE build — this is the real thing: AOT-compiled, ~35 MB installed, ~0.9s cold start.
flutter build apk --release --target-platform android-arm64     # your phone's ABI

# The release APK comes out UNSIGNED (GW-0196). To install on a device, sign it:
KS=~/.android/debug.keystore   # or your own upload key
BT=$(ls -d $ANDROID_HOME/build-tools/* | sort -V | tail -1)
$BT/zipalign -f -p 4 build/app/outputs/flutter-apk/app-release.apk /tmp/gw.apk
$BT/apksigner sign --ks $KS --ks-pass pass:android --ks-key-alias androiddebugkey --key-pass pass:android /tmp/gw.apk
adb install -r /tmp/gw.apk
```

**The #1 gotcha:** if the app feels huge and laggy, you're on a **debug** build. The 300 MB / lag is a debug artifact (an 88 MB JIT `kernel_blob` + all 3 CPU ABIs + un-minified dex), *not* the shipping app. Always evaluate on `--release`. Full breakdown: GW-0194 / GW-0195.

---

## Test assets already in the repo (reuse these)

| Area | Where | What it is |
|------|-------|-----------|
| Never-late proof | `test/scale/`, `test/reachability/` | Deterministic oracle — proves never-late / not-too-early across thousands of simulated rides. Start here to understand the guarantee. |
| EKF replay | `lib/core/ekf/`, `lib/testing/harness_runner.dart` | Feed a GPS/IMU polyline through the fusion + arming pipeline and read the metrics. |
| Semantic UI driving | `test/maestro/*.yaml` | Maestro flows that drive the real app by label (first-time-user, critic tour, red-team deep links). Run with `maestro test <file>`. |
| Native E2E | `integration_test/patrol_alarm_test.dart` | Patrol test that can grant OS permissions + drive the alarm chain on a device/emulator. |
| Charter | `docs/AGENT_TESTING_CHARTER.md` | The original testing philosophy/mandate (three fronts: UX, background reliability, security). |

---

## How we work

- **Log everything.** Every bug, subpar feature, or complaint → a new `GW-####` line in `docs/testing/ISSUES.jsonl`. Ground each claim in evidence (a file:line, a repro command, a device log).
- **Never claim device-proof from a simulation.** If you proved it in a test/emulator, say so. Real-phone behavior is its own category.
- **Discover freely.** These docs tell you what exists and where the bodies are buried. Finding the *next* body is your job — dig.

Questions the docs don't answer? Grep `ISSUES.jsonl`, then read the actual code — it's the source of truth.
