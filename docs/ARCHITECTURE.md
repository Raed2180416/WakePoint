# GeoWake — System Architecture

> Complete end-to-end architecture document. Current as of `production-ready-audit-v2` branch.

---

## 1. Overview

GeoWake is a transit wake-alarm app built with Flutter (Android-first, India-first). The user sets a destination, arms an alarm, and the app tracks their position via GPS + sensor fusion, firing a high-priority alarm before they reach their stop. The core innovation is **GPS-denied tracking** — an Extended Kalman Filter (EKF) uses accelerometer + gyroscope data to estimate position when GPS is unavailable (tunnels, underground metro, urban canyons).

### Tech Stack

| Layer | Technology |
|-------|-----------|
| App framework | Flutter 3.44.x (Dart) |
| Backend | Express.js (Node.js) |
| Maps | Google Maps SDK + server-side proxy |
| Auth | JWT (device-based, no user accounts) |
| IAP | Google Play `in_app_purchase` |
| Ads | Google Mobile Ads |
| Storage | SharedPreferences (key-value), Hive (structured) |
| Localization | Flutter l10n (80+ languages, en + hi primary) |
| Native plugin | `wakepoint_native` (Android-only, full-screen intent + exact alarm) |

---

## 2. App Entry & Service Initialization

### `lib/main.dart` — `main()`

The entry point wraps everything in `runZonedGuarded` to catch uncaught errors. Services initialize in a strict order — critical path services are awaited, everything else is fire-and-forget:

```
main()
├── FlutterError.onError → TelemetryService.recordError
├── PlatformDispatcher.onError → TelemetryService.recordError
├── runZonedGuarded
│   ├── WidgetsFlutterBinding.ensureInitialized()
│   ├── SystemChrome edge-to-edge + transparent bars
│   ├── await Hive.initFlutter()                    ← BLOCKING
│   ├── unawaited: TelemetryService sinks           ← fire-and-forget
│   ├── unawaited: MonetizationService.instance.init()
│   ├── unawaited: GuardianService.instance.init()
│   ├── unawaited: AntiTheftService.instance.load()
│   ├── unawaited: DataAssetPipeline.instance.init()
│   ├── unawaited: HomeWidgetBridge.instance.initialize()
│   ├── unawaited: ShareBackendConfig.configure()
│   ├── if ENABLE_FLUTTER_DRIVER: enableFlutterDriverExtension()
│   └── runApp(MyApp)
```

### `SplashScreen._initializeServices()`

The splash screen handles blocking service init that needs to complete before the UI is usable:

```
├── await ApiClient.instance.initialize()     ← JWT token from backend
├── await NotificationService().initialize()  ← alarm channels
└── TrackingService()                         ← restore active session if any
```

### Navigation

`MyApp` uses `onGenerateRoute` (not named routes) for all navigation. `NavigationService` provides a global `NavigatorKey` for programmatic navigation from services.

---

## 3. Core Tracking Pipeline

This is the heart of GeoWake — the arm → track → alarm spine.

### 3.1 Arming the Alarm

**`HomeScreen._armAlarm()`** (`lib/screens/homescreen.dart`):

1. Validate destination + alarm parameters
2. Run **reliability preflight** (`ReliabilityPreflightRunner`) — checks if the OS can actually deliver the alarm (notifications enabled? exact alarm permission? battery optimization?). Blocks arming only if the delivery channel is dead.
3. `TrackingService.startTracking()` — starts the foreground service
4. Fire-and-forget: `GuardianService.onJourneyArmed()`, `AntiTheftService.startMonitoring()`

### 3.2 TrackingService

**`lib/services/trackingservice.dart`** (~2770 lines)

Intentionally monolithic — the tight coupling between GPS processing, alarm logic, state management, and UI sync would introduce race conditions if split across files.

**Architecture:**
- **Foreground:** `TrackingService` singleton — facade for UI communication, state persistence, session management
- **Background:** `flutter_background_service` isolate — runs the position loop, GPS processing, alarm evaluation

**Data flow:**
```
GPS position → LocationManager → SensorFusion → SnapToRoute → AlarmEvaluator → NotificationService
     ↓                ↓              ↓              ↓              ↓
  EKF pipeline    IMU fusion    route matching   threshold check   full-screen alarm
```

**Key modular components** (in `lib/services/tracking/`):
- `BackgroundHandlers` — registers all background isolate message handlers
- `LocationStreamHandler` — GPS stream setup and management
- `AlarmController` — alarm firing logic
- `HeartbeatMonitor` — foreground↔background liveness check
- `ForegroundBridge` — IPC between isolates
- `PostAlarmMulticast` — post-alarm hooks (guardian, data pipeline)
- `SnapshotRouteRestorer` — session restore after process death

### 3.3 EKF Pipeline (GPS-Denied Tracking)

**`lib/core/ekf/`**

When GPS is unavailable (tunnels, underground metro), the EKF estimates position using:
- **Accelerometer** → ZUPT (Zero-velocity Update) detection → velocity integration
- **Gyroscope** → heading estimation via tilt-filtered angular velocity
- **Route geometry** → constrains estimates to known rail lines
- **Station association** → snaps to nearest station on the route

**Pipeline:**
```
GPS available? → Yes: use GPS, reset EKF state
              → No:  EKF predicts position from IMU data
                        ↓
                  Route geometry constrains estimate
                        ↓
                  Station association snaps to stops
                        ↓
                  Reachability physics computes "can we still make it in time?"
                        ↓
                  Alarm fires if within threshold
```

Key files:
- `ekf_orchestrator.dart` — main EKF state machine
- `ekf_pipeline.dart` — sensor processing pipeline
- `zupt_detector.dart` — zero-velocity detection
- `tilt_filter.dart` — gyroscope tilt compensation
- `motion_classifier.dart` — moving vs stationary classification
- `route_geometry.dart` — rail line geometry constraints
- `station_association.dart` — snap to station stops
- `gps_degradation_detector.dart` — GPS quality monitoring

### 3.4 Reachability (Never-Late Physics)

**`lib/core/reachability/reachability.dart`**

The never-late guarantee: the alarm must fire on time or not at all — never silently late. Reachability physics computes whether the user can still reach their destination given:
- Current estimated position (from GPS or EKF)
- Remaining distance along the route
- Expected travel speed (from route geometry + historical data)
- Alarm threshold (distance, time, or stops)

If the user cannot possibly reach the destination in time for the alarm to fire at the threshold, the alarm fires **now** rather than risk being late.

### 3.5 Alarm Delivery

**`lib/services/notification_service.dart`** (~1758 lines)

`showWakeUpAlarm()` is the core alarm trigger:
1. Prevents duplicate alarms (`_alarmCurrentlyShowing` flag)
2. Persists alarm state to SharedPreferences (for restore after process death)
3. Configures Android notification:
   - Channel: `geowake_alarm_channel_v4` (Importance.max, Priority.max)
   - `fullScreenIntent: true` (via `WakepointNative.canUseFullScreenIntent()`)
   - `ongoing: true`, `autoCancel: false`
   - Actions: "Stop Alarm", "End Tracking"
   - `audioAttributesUsage: AudioAttributesUsage.alarm`
4. Plays alarm sound + vibration **in parallel** via `Future.wait`:
   - `AlarmPlayer.playSelected()` — custom alarm sound
   - `_startAlarmVibrationLoop()` — synchronized vibration pattern
   - `_notificationsPlugin.show()` — the notification itself

**Backstop mechanisms:**
- `scheduleEtaBackstop()` — OS-scheduled exact alarm via `WakepointNative.scheduleExactAlarm()` as a safety net for total process death
- `TrackingStateStore` — persists alarm state so a restored session can re-fire if needed

---

## 4. Monetization

### 4.1 PremiumService

**`lib/services/monetization/premium_service.dart`**

Pure entitlement logic, dependency-injected for testability. Two paths to Pro:
1. **Permanent one-time unlock** — `geowake_pro_onetime` (₹199), non-consumable
2. **Rewarded day pass** — 24-hour Pro via rewarded video ad

**Feature gates:**
- **Always free:** `canUseCoreAlarm`, `canUseBasicReliability`, `canUseBackstopAlarm`, `canUseSingleActiveRoute` — all return `true` unconditionally
- **Pro-gated:** `canUseAntiTheft`, `canUseGuardianMode`, `canUseCustomAlarmSounds`, `canUseWidget`, `isAdFree`

Persistence: single SharedPreferences key `geowake_entitlement_v1`, format `"0|1;expiryMs"`. Fail-closed parsing — never grants Pro from ambiguous/tampered state.

### 4.2 MonetizationService

**`lib/services/monetization/monetization_service.dart`**

App-level facade that assembles the monetization stack:
- `IapPurchaseBackend` — real Google Play `in_app_purchase` implementation
- `PremiumService` — entitlement logic
- `AdService` — Google Mobile Ads
- `AdPolicy` — ad frequency capping (ride counter)

Key features:
- **Reactive tier:** `tierListenable` (ValueNotifier) — UI rebuilds instantly on purchase
- **UPI pending purchases:** `pendingPurchasesListenable` — shows "Payment processing…" banner
- **Purchase reconciliation:** `queryPastPurchases()` on every app launch (catches UPI payments that cleared overnight)
- **Fail-safe:** any error → free tier, app still works

### 4.3 IapPurchaseBackend

**`lib/services/monetization/purchase_backend_impl.dart`**

Concrete `PurchaseBackend` using `in_app_purchase` plugin:
- Handles all purchase states: `purchased`, `restored`, `error`, `canceled`, `pending`
- UPI pending state: purchase doesn't complete immediately (bank processing), shows banner
- `onEntitlementChanged` callback fires when ownership arrives asynchronously
- `onPendingChanged` callback fires when pending set changes
- `queryPastPurchases()` reconciles purchases completed while app wasn't running

### 4.4 Paywall

**`lib/screens/monetization/paywall_screen.dart`**

Single upsell surface. Shows:
- Pro benefits list
- One-time purchase CTA (₹199)
- Rewarded day pass option
- Restore purchases button
- UPI pending purchase banner (if applicable)
- Legal links (terms, privacy)

### 4.5 Post-Arrival

**`lib/screens/monetization/post_arrival_screen.dart`** + **`lib/services/monetization/post_arrival_service.dart`**

After the alarm fires and tracking stops, shows a post-arrival screen with:
- Journey summary
- Ad display (free tier, frequency-capped)
- Upsell to Pro

---

## 5. Anti-Theft Service

**`lib/services/anti_theft_service.dart`**

Pro-gated phone snatch detection for sleeping commuters.

**Sensor fusion approach:**
- **User accelerometer** (20Hz) → rolling Z-score baseline → anomaly detection
- **Gyroscope** (20Hz) → rotation magnitude fusion → reduces false positives
- **Charger removal** → optional trigger via `Battery().onBatteryStateChanged`

**Detection algorithm:**
1. **Calibration phase** (first few seconds) — builds baseline window
2. **Monitoring phase** — Z-score of each accelerometer reading against baseline
3. **Spike detection** — if Z-score exceeds sensitivity threshold AND gyro magnitude confirms rotation → fire alarm
4. **Cooldown** — after dismissal, won't re-trigger for `_cooldownDuration`

**Sensitivity levels:**
- Low: higher Z-score threshold (fewer false positives)
- Medium: balanced
- High: lower threshold (more sensitive)

**Fail-open:** sensor errors disable monitoring, never crash the app or affect the core alarm.

---

## 6. Data Asset Pipeline

**`lib/services/data_asset/`**

Consent-gated, differentially private aggregate mobility data pipeline. The company's data asset is not the alarm — it's anonymous aggregate origin-destination flow data.

### 6.1 Consent

**`mobility_consent_service.dart`**
- **Default OFF** — no data sharing without explicit opt-in
- **Versioned consent** — `kConsentNoticeVersion` must match; version change forces re-consent
- **One-tap withdrawal** — disables sharing + triggers `onWithdraw` callback for on-device erasure
- **Consent receipt** — `consentReceiptJson()` exports proof of consent

### 6.2 Pipeline

**`data_asset_pipeline.dart`**

```
Tracking session → OD aggregator → Station binner → K-anonymity filter → DP noise → Release candidate → Egress
```

1. **OD aggregator** — counts origin-destination cell transitions
2. **Station binner** — groups by station catchment areas
3. **K-anonymity filter** — suppresses cells with < k contributions (k=5)
4. **Differential privacy** — adds Laplace noise (ε per cell)
5. **Contribution cap** — limits per-device contributions per time window
6. **Release candidate matrix** — the output, sent to backend merge engine

### 6.3 Egress

**`http_candidate_egress_sink.dart`**
- Uploads `ReleaseCandidateMatrix` to backend
- **No-op** when `kDataAssetEgressEnabled` is false or endpoint is empty
- Uses `ApiClient.instance.authToken` for auth
- All errors swallowed (fail-open — never affects the core alarm)

### 6.4 Data Structures

**`od_cell.dart`** — coordinate-free O-D cells:
- `OdCellKey` — station ID pairs (no coordinates, prevents re-identification)
- `OdCell` — raw counts
- `ReleaseCandidateCell` — post-DP, pre-merge
- `ReleasedCell` — final released aggregate (only constructable by backend merge engine)

---

## 7. Journey Sharing

### 7.1 Share Backend

**`lib/services/share/live_share_backend.dart`** — `HttpShareBackend`
- Creates share sessions, pushes location updates, marks arrival, revokes shares
- `_safeId()` sanitizes share IDs for URL path segments (prevents path traversal)
- Auth via token header

**`lib/services/share/share_backend_config.dart`**
- Build-time config: `GEOWAKE_SHARE_BASE_URL`, `GEOWAKE_SHARE_TOKEN`, `GEOWAKE_SHARE_DOMAIN`
- `buildBackend()` returns `HttpShareBackend` or `NoopShareBackend`
- `configure()` wires sharer + follower services

### 7.2 Guardian Mode

**`lib/services/share/guardian_service.dart`**
- Pro-only: auto-share every commute with a saved contact
- Sends "arrived safely" push notification when tracking stops
- Observer hangs off `PostAlarmMulticast` — runs AFTER alarm fires, never delays it
- Inert unless Pro + enabled

### 7.3 Deep Links

**`lib/services/share/share_deep_link.dart`**
- Parses `geowake://j/{id}` and `https://<domain>/j/{id}` App Links
- Opens `FriendsRidesScreen` to follow a friend's ride
- Fail-safe: bad links never crash the app

### 7.4 Journey Share Service

**`lib/services/share/journey_share_service.dart`**
- Binds to `TrackingService.locationStream` for live position relay
- `ingestLocation` self-gates on active share (inert otherwise)
- Never touches the arm → track → alarm spine

---

## 8. Telemetry

**`lib/services/telemetry/`**

- `TelemetryService` — singleton, multi-sink (in-memory + file JSONL + optional HTTP)
- `FileTelemetrySink` — durable JSONL on disk, survives process death
- `HttpTelemetrySink` — optional network egress, INERT by default (empty URL = no network sink)
- `TelemetrySession` — session metadata (device, OS, app version)
- `TelemetryReportBuilder` — constructs diagnostic reports

All telemetry is best-effort: errors are swallowed, never block startup or crash the app.

---

## 9. Reliability

### 9.1 Preflight

**`lib/services/reliability/`**
- `ReliabilityPreflightRunner` — pre-arm checks
- `ReliabilityPreflightService` — probe definitions
- `ReliabilityProbeImpl` — platform checks (notification channel, exact alarm, battery optimization)

Results: `ok` (proceed), `warn` (proceed with dialog), `block` (refuse to arm — dead delivery channel).

### 9.2 Process Death Recovery

- `TrackingStateStore` — persists session state (active, paused, alarm fired, snapshot)
- `SnapshotRouteRestorer` — restores route + tracking state after process death
- `WakepointNative.scheduleExactAlarm()` — OS-scheduled exact alarm as backstop for total process death
- `SplashScreen._checkStateAndNavigate()` — restores session or shows alarm on launch

### 9.3 OEM Survival

- Foreground service with location type (survives screen-off)
- Heartbeat monitor (foreground↔background liveness)
- `OemAutostartService` — handles OEM battery killer scenarios
- `SoftLockManager` — prevents concurrent tracking sessions

---

## 10. UI Screens

| Screen | File | Purpose |
|--------|------|---------|
| Splash | `splash_screen.dart` | Service init, session restore |
| Home | `homescreen.dart` | Destination search, alarm config, arm |
| PreloadMap | `preload_map_screen.dart` | Map preload before tracking |
| MapTracking | `maptracking.dart` | Live tracking view with route + ETA |
| Paywall | `monetization/paywall_screen.dart` | Pro upsell |
| PostArrival | `monetization/post_arrival_screen.dart` | Journey summary + ad |
| DataConsent | `mobility_data_consent_screen.dart` | Data sharing opt-in |
| Guardian | `guardian_setup_screen.dart` | Guardian contact setup |
| AntiTheft | `anti_theft_setup_screen.dart` | Anti-theft config |
| FriendsRides | `friends_rides_screen.dart` | Follow shared rides |
| ReportProblem | `report_problem_screen.dart` | Diagnostic report |
| Ringtones | `ringtones_screen.dart` | Alarm sound selection |
| Settings | `settingsdrawer.dart` | App settings drawer |

---

## 11. Configuration

### 11.1 App Config

**`lib/config/app_config.dart`** — API URLs, bundle ID
**`lib/config/power_policy.dart`** — GPS sampling rates, battery thresholds
**`lib/config/deviation_config.dart`** — deviation detection thresholds
**`lib/config/fire_decision_config.dart`** — alarm fire decision parameters

### 11.2 Build-Time Defines

| Define | Default | Purpose |
|--------|---------|---------|
| `GEOWAKE_TELEMETRY_URL` | `''` | Telemetry HTTP endpoint |
| `GEOWAKE_TELEMETRY_TOKEN` | `''` | Telemetry auth token |
| `ENABLE_FLUTTER_DRIVER` | `false` | Flutter Driver extension |
| `GEOWAKE_SHARE_BASE_URL` | Railway URL | Journey share backend |
| `GEOWAKE_SHARE_TOKEN` | `''` | Share backend auth |
| `GEOWAKE_SHARE_DOMAIN` | Railway domain | Share deep link domain |

### 11.3 Android Build

**`android/app/build.gradle`:**
- `applicationId: com.geowake.app`
- `minSdkVersion: 24`, `targetSdkVersion: 35`
- `testInstrumentationRunner: pl.leancode.patrol.PatrolJUnitRunner` (E2E)
- Google Maps API key from `key.properties`

---

## 12. Backend

See [docs/BACKEND.md](BACKEND.md) for full API reference.

**Express.js server** (`geowake-server/src/`):
- **Auth:** JWT device authentication (no user accounts)
- **Maps proxy:** Google Maps API proxy with caching (Directions, Places, Geocoding, Nearby Search)
- **Aggregate:** Device ingest + dashboard endpoints for mobility data
- **Security:** Helmet, CORS, rate limiting, slow-down, compression
- **Cache:** NodeCache with per-type TTLs

---

## 13. Testing

See [docs/TESTING.md](TESTING.md) for full testing guide.

**1373+ tests** across:
- Core: EKF, clock, reachability, alarm logic
- Services: tracking, monetization, share, telemetry, data asset
- Integration: lifecycle restore, offline, preflight
- Scale: reachability at scale, never-late stress
- Dashboard: simulation playground, E2E

**CI gates** (`.github/workflows/ci.yml`):
1. `flutter analyze lib/ --no-fatal-infos`
2. Never-late replay harness
3. Reachability physics proofs
4. Scale tests
5. Playground E2E
6. Monotonic clock guard
7. Metro data integrity
8. Full test suite

---

## 14. Native Plugin

**`packages/wakepoint_native/`** — Android-only Flutter plugin:

- `canUseFullScreenIntent()` — checks Android 14+ (`USE_FULL_SCREEN_INTENT`) permission
- `scheduleExactAlarm()` — schedules an OS-level exact alarm via `AlarmManager` as a process-death backstop

Platform channel: `wakepoint_native`
