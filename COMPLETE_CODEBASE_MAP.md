# GeoWake Complete Codebase Map & Analysis
## Created: December 24, 2025 | Systematic Line-by-Line Analysis
## Last Updated: December 24, 2025 - Additional Issue Discovery Pass

This document provides a **complete detailed map** of how every component in the GeoWake codebase works together, including all data flows, dependencies, logical gaps, and inconsistencies.

### ISSUE SUMMARY
| Severity | Count | Description |
|----------|-------|-------------|
| 🔴 CRITICAL | 8 | Must fix before production |
| 🟡 MODERATE | 17 | Should fix soon |
| 🟢 MINOR | 10 | Code quality improvements |
| 🟣 NEWLY DISCOVERED | 8 | Found via grep searches |
| 🔵 ALGORITHMIC | 24 | Logic bugs, edge cases, race conditions |
| **TOTAL** | **67** | Across ~15,500 lines of code |

**See Also:** [ALGORITHMIC_ANALYSIS.md](ALGORITHMIC_ANALYSIS.md) for deep dive into:
- 5 Critical Logic Bugs (stop interpolation, 60% rule conflicts, etc.)
- 5 Edge Case Handling Issues
- 4 Performance Bottlenecks
- 5 Race Conditions & Concurrency Bugs
- 5 Business Logic Correctness Issues

---

# PART 1: SYSTEM ARCHITECTURE OVERVIEW

## 1.1 High-Level Component Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              FLUTTER APP                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│  ┌─────────────┐    ┌──────────────┐    ┌─────────────────┐                 │
│  │ HomeScreen  │───▶│ MapTracking  │───▶│ NotificationSvc │                 │
│  │ (Route Setup)    │ (Active View) │    │ (Alarm Delivery)│                 │
│  └──────┬──────┘    └──────┬───────┘    └────────┬────────┘                 │
│         │                  │                      │                          │
│         ▼                  ▼                      ▼                          │
│  ┌──────────────────────────────────────────────────────────────┐           │
│  │                   TRACKING SERVICE (4441 lines)               │           │
│  │  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────────────┐ │           │
│  │  │ GPS Loop │ │ETA Engine│ │Stop Logic│ │ Route Management │ │           │
│  │  └────┬─────┘ └────┬─────┘ └────┬─────┘ └────────┬─────────┘ │           │
│  │       └────────────┴────────────┴────────────────┘           │           │
│  └──────────────────────────────────────────────────────────────┘           │
│                              │                                               │
│                              ▼                                               │
│  ┌──────────────────────────────────────────────────────────────┐           │
│  │              FLUTTER BACKGROUND SERVICE                       │           │
│  │              (Runs when app is minimized/killed)              │           │
│  └──────────────────────────────────────────────────────────────┘           │
└─────────────────────────────────────────────────────────────────────────────┘
                               │
                               │ HTTPS
                               ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         RAILWAY SERVER (Node.js)                             │
│  ┌─────────────┐    ┌──────────────┐    ┌─────────────────┐                 │
│  │ Auth Middle │───▶│ Maps Proxy   │───▶│ Google Maps API │                 │
│  │ (Bundle ID) │    │ (Directions) │    │ (External)      │                 │
│  └─────────────┘    └──────────────┘    └─────────────────┘                 │
└─────────────────────────────────────────────────────────────────────────────┘
```

## 1.2 Process Lifecycle

```
APP LAUNCH
    │
    ▼
┌─────────────────┐
│ main.dart       │──▶ Initialize Hive, Themes, Routes
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ SplashScreen    │──▶ Check existing tracking state
└────────┬────────┘    │
         │             ├─▶ If tracking active: Resume to MapTracking
         │             └─▶ If not tracking: Go to HomeScreen
         ▼
┌─────────────────┐
│ HomeScreen      │──▶ User selects destination + alarm settings
└────────┬────────┘
         │
         ▼ (Wake Me! pressed)
┌─────────────────┐
│ Permission Flow │──▶ Location → Background Location → Notifications
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Direction Fetch │──▶ ApiClient → Railway Server → Google Directions API
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ TrackingService │──▶ startTracking() + registerRouteFromDirections()
│ .startTracking  │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ MapTracking     │──▶ Display route, listen to tracking updates
│ Screen          │
└────────┬────────┘
         │
         ▼ (User arrives / alarm triggers)
┌─────────────────┐
│ NotificationSvc │──▶ showWakeUpAlarm() + AlarmPlayer + Haptics
│ .showWakeUp     │
└─────────────────┘
```

---

# PART 2: DETAILED DATA FLOW ANALYSIS

## 2.1 Route Registration Flow (Critical Path)

This is the most complex flow in the app. Here's exactly how it works:

### Step 1: HomeScreen._proceedWithDirections()
**File:** `lib/screens/homescreen.dart` (Lines 500-700)

```
User taps "Wake Me!"
         │
         ▼
_onWakeMePressed()
         │
         ├─▶ PermissionService.requestEssentialPermissions()
         │   └─▶ Location → Background Location → Notifications
         │
         ▼
_proceedWithDirections()
         │
         ├─▶ Get current position (cached if <30s old, else fresh GPS)
         │
         ├─▶ If metroMode: MetroStopService.validateMetroRoute()
         │   └─▶ Verifies transit stops exist near destination
         │
         ├─▶ _validateSameState() [PARALLEL with directions fetch]
         │   └─▶ Reverse geocode both points, compare admin_area_level_1
         │
         ├─▶ _fetchDirections() via OfflineCoordinator
         │   └─▶ DirectionService → ApiClient → Railway → Google
         │
         ├─▶ If stops mode: StopLogicEngine.validateThreshold()
         │   └─▶ Ensures user's "N stops" doesn't exceed route's stops
         │
         ├─▶ TrackingStateStore.saveSnapshot() [Persist for app restore]
         │
         ├─▶ TrackingService.startTracking()
         │
         └─▶ TrackingService.registerRouteFromDirections() [fire-and-forget]
```

### Step 2: TrackingService.registerRouteFromDirections()
**File:** `lib/services/trackingservice.dart` (Lines 1200-1500)

```
registerRouteFromDirections(directions, origin, destination, transitMode)
         │
         ├─▶ Parse directions['routes'][0]['legs'][0]
         │   ├─▶ Extract overview_polyline → decode → _fullPolyline
         │   ├─▶ Extract duration.value → _initialEtaSeconds
         │   └─▶ Extract distance.value → _totalRouteMeters
         │
         ├─▶ TransferUtils.buildStepBoundariesAndStops(directions)
         │   └─▶ Returns: { bounds: [meters], stops: [cumulative], durations: [seconds] }
         │
         ├─▶ TransferUtils.buildRouteEvents(directions)
         │   └─▶ Returns: List<RouteEventBoundary> for transfers/mode changes
         │
         ├─▶ TransferUtils.extractTransitLegStops(directions)
         │   └─▶ Returns: List<TransitLegStops> with stop positions per leg
         │
         ├─▶ RouteRegistry.upsert(RouteEntry(...))
         │   └─▶ Caches simplified polyline + metadata
         │
         ├─▶ ActiveRouteManager.setActive(routeKey)
         │
         └─▶ SimulationClient.broadcastRoute() [if playground mode]
```

### Step 3: Background Position Processing Loop
**File:** `lib/services/trackingservice.dart` (Lines 800-1200)

```
_onServiceStart() [Called when background service starts]
         │
         ├─▶ _positionStream = Geolocator.getPositionStream(...)
         │   └─▶ Android: HIGH accuracy, 5m distance filter, 3s interval
         │
         └─▶ _positionStreamSubscription.listen(_processPosition)

_processPosition(Position position)
         │
         ├─▶ GUARD: Check _isTracking, _isStopping, _alarmFired
         │
         ├─▶ Check notifications muted (TrackingStateStore.notificationsMuted())
         │
         ├─▶ SnapToRouteEngine.snap(position, _fullPolyline)
         │   └─▶ Returns: snappedPoint, lateralOffsetMeters, progressMeters
         │
         ├─▶ EtaEngine.computeEta(routeCoords, gps, isMetroMode, stepData)
         │   └─▶ Returns: etaSeconds, remainingMeters, snappedPoint, sigmaEta
         │
         ├─▶ If transitMode: StopLogicEngine.calculateRemainingStops()
         │   └─▶ Returns: remainingStops, targetName, isDestination
         │
         ├─▶ ALARM EVALUATION:
         │   ├─▶ Distance mode: remainingMeters <= threshold * 1000
         │   ├─▶ Time mode: etaSeconds <= threshold * 60
         │   └─▶ Stops mode: remainingStops <= threshold
         │
         ├─▶ If threshold met AND NOT _alarmFired:
         │   └─▶ _triggerAlarm()
         │
         └─▶ Broadcast state via IPC + SimulationClient
```

---

## 2.2 Alarm Trigger Flow (Critical Path)

**File:** `lib/services/trackingservice.dart` (Lines 700-800)

```
_triggerAlarm()
         │
         ├─▶ Set _alarmFired = true
         │
         ├─▶ TrackingStateStore.setAlarmFired(true)
         │
         ├─▶ service.invoke('triggerAlarm', {...})
         │   └─▶ IPC to foreground Flutter
         │
         └─▶ If foreground service instance available:
             └─▶ NotificationService.showWakeUpAlarm()

NotificationService.showWakeUpAlarm() [notification_service.dart:400-600]
         │
         ├─▶ AlarmPlayer.playSelected()
         │   └─▶ Loads ringtone from SharedPreferences key 'alarm_sound'
         │   └─▶ AudioPlayer().play(AssetSource/DeviceFileSource)
         │
         ├─▶ AlarmHaptics.start()
         │   └─▶ Native Android vibration pattern: [0, 500, 200, 500, ...]
         │   └─▶ Fallback to Vibration plugin if native fails
         │
         └─▶ _plugin.show(notificationId, title, body, details)
             └─▶ Android: Full-screen intent, ongoing, high priority
             └─▶ Actions: "Stop" and "Snooze"
```

---

## 2.3 Server Communication Flow

**File:** `lib/services/api_client.dart` → `geowake-server/`

```
ApiClient.getDirections(origin, destination, mode)
         │
         ├─▶ Build request to: https://geowake-production.up.railway.app/api/directions
         │
         ├─▶ Add headers:
         │   ├─▶ X-App-Bundle-Id: "com.example.geowake2"  ⚠️ MISMATCH!
         │   └─▶ Content-Type: application/json
         │
         └─▶ POST { origin, destination, mode, transit_mode }

Railway Server (auth.js middleware)
         │
         ├─▶ Extract X-App-Bundle-Id header
         │
         ├─▶ Compare to config.APP_BUNDLE_ID (env var)
         │   └─▶ If mismatch: 403 Forbidden
         │
         └─▶ If match: next() to mapsController

mapsController.getDirections()
         │
         ├─▶ Check cache (NodeCache, 5 min TTL)
         │
         ├─▶ If cache miss:
         │   └─▶ fetch(`https://maps.googleapis.com/maps/api/directions/json?...&key=${GOOGLE_API_KEY}`)
         │
         └─▶ Return directions JSON to app
```

---

# PART 3: COMPONENT-BY-COMPONENT ANALYSIS

## 3.1 TrackingService (THE HEART OF THE APP)

**File:** `lib/services/trackingservice.dart`
**Lines:** 4,441 (🔴 CRITICAL SIZE - needs splitting)

### Global State Variables (Lines 1-100)

```dart
// These are MODULE-LEVEL globals in the background isolate:
bool _isTracking = false;
bool _alarmFired = false;
bool _isStopping = false;
String _alarmMode = 'distance';
double _alarmValue = 1.0;
LatLng? _destination;
String _destinationName = '';
bool _transitMode = false;

// Route data (set during registerRouteFromDirections)
List<LatLng> _fullPolyline = [];
double _totalRouteMeters = 0.0;
int _initialEtaSeconds = 0;
List<double> _stepBoundsMeters = [];
List<double> _stepStopsCumulative = [];
List<int> _stepDurations = [];
List<RouteEventBoundary> _routeEvents = [];
List<TransitLegStops> _transitLegStops = [];

// Progress tracking
double _currentProgressMeters = 0.0;
int _lastSnapIndex = 0;
double _snappedOffsetMeters = 0.0;
```

### ⚠️ PROBLEM: Dual State Systems

The code maintains state in TWO places:
1. **Module-level globals** (above) - Used by background isolate
2. **TrackingService singleton instance fields** - Used by foreground

```dart
// In TrackingService class:
class TrackingService {
  static final TrackingService _instance = TrackingService._internal();
  
  // DUPLICATED state (also exists as globals):
  bool _isTracking = false;
  LatLng? _destination;
  String _destinationName = '';
  // ...etc
}
```

**Impact:** State can desync between foreground and background, causing:
- Alarm triggers with stale destination name
- UI showing different progress than actual tracking
- Resume bugs after app kill/restart

### Key Methods Analysis

#### `startTracking()` (Lines 200-350)
```dart
Future<void> startTracking({
  required LatLng destination,
  required String destinationName,
  required String alarmMode,
  required double alarmValue,
}) async {
  // Sets both global AND instance state
  _destination = destination;
  _destinationName = destinationName;
  _alarmMode = alarmMode;
  _alarmValue = alarmValue;
  _isTracking = true;
  _alarmFired = false;
  
  // Starts background service
  await _service.startService();
  _service.invoke('startTracking', {...});
}
```

#### `_processPosition()` (Lines 800-1200) - THE BIG ONE

This 400-line function is the core tracking loop. Here's its structure:

```dart
Future<void> _processPosition(Position position) async {
  // 1. GUARD CLAUSES (Lines 810-850)
  if (!_isTracking) return;
  if (_isStopping) return;
  if (_alarmFired) return;
  if (await TrackingStateStore.notificationsMuted()) return;
  
  // 2. GPS HEALTH CHECK (Lines 850-880)
  _gpsHealthMonitor.ingestGpsUpdate(position);
  
  // 3. SNAP TO ROUTE (Lines 880-920)
  final snap = SnapToRouteEngine.snap(
    point: LatLng(position.latitude, position.longitude),
    polyline: _fullPolyline,
    hintIndex: _lastSnapIndex,
  );
  _currentProgressMeters = snap.progressMeters;
  _snappedOffsetMeters = snap.lateralOffsetMeters;
  _lastSnapIndex = snap.segmentIndex;
  
  // 4. ETA CALCULATION (Lines 920-980)
  final eta = _etaEngine.computeEta(
    routeCoords: _fullPolyline,
    gps: position,
    isMetroMode: _transitMode,
    stepBoundsMeters: _stepBoundsMeters,
    stepDurationsSeconds: _stepDurations,
    totalRouteMeters: _totalRouteMeters,
  );
  
  // 5. STOPS CALCULATION (Lines 980-1050) - Only for transit mode
  double remainingStops = 0;
  if (_transitMode && _alarmMode == 'stops') {
    final stopResult = _stopLogicEngine.calculateRemainingStops(
      progressMeters: _currentProgressMeters,
      stepBoundsMeters: _stepBoundsMeters,
      stepStopsCumulative: _stepStopsCumulative,
      routeEvents: _routeEvents,
      firedEventIndexes: _firedEventIndexes,
    );
    if (stopResult != null) {
      remainingStops = stopResult.remainingStops;
    }
  }
  
  // 6. ALARM EVALUATION (Lines 1050-1150)
  bool shouldTrigger = false;
  switch (_alarmMode) {
    case 'distance':
      shouldTrigger = eta.remainingMeters <= _alarmValue * 1000;
      break;
    case 'time':
      shouldTrigger = eta.etaSeconds <= _alarmValue * 60;
      break;
    case 'stops':
      shouldTrigger = remainingStops <= _alarmValue;
      break;
  }
  
  // 7. TRIGGER ALARM (Lines 1150-1180)
  if (shouldTrigger && !_alarmFired) {
    await _triggerAlarm();
  }
  
  // 8. BROADCAST STATE (Lines 1180-1200)
  _broadcastTrackingState(...);
}
```

---

## 3.2 EtaEngine - Time/Distance Estimation

**File:** `lib/services/eta_engine.dart`
**Lines:** 476

### Core Algorithm

```dart
computeEta({routeCoords, gps, isMetroMode, stepBoundsMeters, stepDurationsSeconds, totalRouteMeters}) {
  // 1. Map-match GPS to route
  final match = matchToRoute(routeCoords, currentPoint);
  final remainingMeters = match.remainingMeters;
  
  // 2. Smooth speed with exponential filter
  final rawSpeed = gps.speed > 0 ? gps.speed : _estimateSpeedFromLast(gps);
  final vEst = _updateSmoothedSpeed(rawSpeed);  // α = 0.3
  
  // 3. Physics-based ETA
  double effectiveSpeed = max(vEst, vMin);  // vMin = 0.5 m/s
  if (isMetroMode && effectiveSpeed > 2.5) {
    effectiveSpeed = max(effectiveSpeed, 5.0);  // Clamp for metro
  }
  double etaSeconds = remainingMeters / effectiveSpeed;
  
  // 4. Smart ETA using step durations (if available)
  if (stepBoundsMeters != null && stepDurationsSeconds != null) {
    // Find current step, use current speed for this step
    // Use planned durations for future steps
    // This fixes "walking to train = optimistic ETA" bug
  }
  
  // 5. Compute uncertainty (sigma_eta)
  final sigmaP = max(gps.accuracy, 5.0);
  final sigmaV = _computeSigmaV();  // From speed window variance
  final sigmaEta = sqrt(pow(sigmaP/effectiveSpeed, 2) + pow((remainingMeters*sigmaV)/pow(effectiveSpeed,2), 2));
  
  return (etaSeconds, remainingMeters, vEst, sigmaEta, snappedPoint);
}
```

### ⚠️ PROBLEM: Metro Mode Speed Clamp

```dart
if (isMetroMode && effectiveSpeed > 2.5) {
  effectiveSpeed = max(effectiveSpeed, 5.0);
}
```

This clamp only activates if speed > 2.5 m/s. But when standing still in a metro (speed ≈ 0), the ETA uses `vMin = 0.5 m/s`, giving VERY long ETAs that may never trigger time-based alarms.

---

## 3.3 StopLogicEngine - Transit Stop Counting

**File:** `lib/services/stop_logic_engine.dart`
**Lines:** 408

### Core Algorithm

```dart
calculateRemainingStops({progressMeters, stepBoundsMeters, stepStopsCumulative, routeEvents, firedEventIndexes}) {
  // 1. Find next unfired switch point (transfer/mode change)
  int? nextSwitchIndex;
  for (int i = 0; i < routeEvents.length; i++) {
    if (!firedEventIndexes.contains(i) && routeEvents[i].meters > progressMeters) {
      nextSwitchIndex = i;
      break;
    }
  }
  
  // 2. Determine target: next switch OR final destination
  final isDestination = nextSwitchIndex == null;
  final targetMeters = isDestination ? totalRouteMeters : routeEvents[nextSwitchIndex].meters;
  
  // 3. Interpolate stops at current position and target
  final progressStops = _interpolateStops(progressMeters, stepBoundsMeters, stepStopsCumulative);
  final targetStops = _interpolateStops(targetMeters, stepBoundsMeters, stepStopsCumulative);
  
  // 4. Calculate remaining
  double remainingStops = targetStops - progressStops;
  
  // 5. HYBRID FIX: For walking legs (no transit stops), use virtual stops
  if (remainingStops < 0.1) {
    final dist = targetMeters - progressMeters;
    if (dist > 0) {
      remainingStops = dist / 500.0;  // 500m = 1 virtual stop
    }
  }
  
  return (remainingStops, targetName, isDestination, ...);
}
```

### How Stop Interpolation Works

```dart
_interpolateStops(meters, stepBoundsMeters, stepStopsCumulative) {
  // Find which step contains this meter position
  for (int i = 0; i < stepBoundsMeters.length; i++) {
    if (meters <= stepBoundsMeters[i]) {
      final stepStart = i == 0 ? 0 : stepBoundsMeters[i-1];
      final stepEnd = stepBoundsMeters[i];
      final stopsStart = i == 0 ? 0 : stepStopsCumulative[i-1];
      final stopsEnd = stepStopsCumulative[i];
      
      // Linear interpolation within step
      final fraction = (meters - stepStart) / (stepEnd - stepStart);
      return stopsStart + (stopsEnd - stopsStart) * fraction;
    }
  }
}
```

---

## 3.4 TransferUtils - Route Event Detection

**File:** `lib/services/transfer_utils.dart`
**Lines:** 689

### buildRouteEvents() - Identifies Switch Points

```dart
static List<RouteEventBoundary> buildRouteEvents(Map<String, dynamic> directions) {
  final events = <RouteEventBoundary>[];
  double cum = 0.0;
  String? prevMode;
  
  // Flatten all steps across all legs
  final allSteps = <Map<String, dynamic>>[];
  for (final leg in directions['routes'][0]['legs']) {
    for (final step in leg['steps']) {
      allSteps.add(step);
    }
  }
  
  for (int i = 0; i < allSteps.length; i++) {
    final step = allSteps[i];
    final mode = _canonicalEventMode(step);  // 'METRO', 'WALKING', 'DRIVING', etc.
    final dist = step['distance']['value'];
    
    // MODE CHANGE DETECTION
    if (prevMode != null && mode != prevMode) {
      // Only Walking ↔ Metro are valid switch points (user requirement)
      final isWalkingMetro = (prevMode == 'WALKING' && mode == 'METRO') ||
                             (prevMode == 'METRO' && mode == 'WALKING');
      
      if (isWalkingMetro) {
        // Skip "interchange walks" (platform changes during transfer)
        if (!isInterchangeWalk && !isInterchangeBoarding) {
          events.add(RouteEventBoundary(meters: cum, type: 'mode_change', ...));
        }
      }
    }
    
    cum += dist;
    
    // TRANSFER DETECTION (within metro legs)
    if (mode == 'METRO') {
      final curLine = step['transit_details']['line']['short_name'];
      // Look ahead for next metro step
      final nextLine = /* find next metro step's line */;
      if (nextLine != null && nextLine != curLine) {
        events.add(RouteEventBoundary(meters: cum, type: 'transfer', ...));
      }
    }
    
    prevMode = mode;
  }
  
  // Deduplicate events within 400m of each other (first wins)
  return _deduplicateEvents(events, 400.0);
}
```

---

## 3.5 SnapToRouteEngine - GPS to Route Matching

**File:** `lib/services/snap_to_route.dart`
**Lines:** 106

### Core Algorithm

```dart
static SnapResult snap({point, polyline, precomputedCumMeters, hintIndex, searchWindow}) {
  // 1. Use hint index to limit search (performance optimization)
  int start = max(0, hintIndex - searchWindow);
  int end = min(polyline.length - 2, hintIndex + searchWindow);
  
  double bestDist = double.infinity;
  LatLng bestPoint;
  int bestIdx;
  double bestProgress;
  
  // 2. Find closest segment
  for (int i = start; i <= end; i++) {
    final A = polyline[i];
    final B = polyline[i + 1];
    final proj = _projectPointOnSegment(point, A, B);
    final d = _dist(point, proj);
    
    if (d < bestDist) {
      bestDist = d;
      bestPoint = proj;
      bestIdx = i;
      bestProgress = cumMeters[i] + _dist(A, proj);
    }
  }
  
  return SnapResult(
    snappedPoint: bestPoint,
    lateralOffsetMeters: bestDist,  // How far off-route
    progressMeters: bestProgress,    // How far along route
    segmentIndex: bestIdx,
  );
}
```

### ⚠️ PROBLEM: Search Window Too Small

```dart
int searchWindow = 20;
```

With a 20-segment window, if the user jumps (GPS glitch, tunnel exit), the snap might miss the correct segment and "teleport" the progress backwards or forwards incorrectly.

---

## 3.6 NotificationService - Alarm Delivery

**File:** `lib/services/notification_service.dart`
**Lines:** 1,495

### showWakeUpAlarm() Flow

```dart
Future<void> showWakeUpAlarm({required String title, required String body}) async {
  // 1. Play alarm sound
  try {
    await AlarmPlayer.playSelected();
  } catch (e) {
    // Silent failure - alarm might not play!
  }
  
  // 2. Start haptic vibration
  try {
    await AlarmHaptics.start();
  } catch (e) {
    // Silent failure
  }
  
  // 3. Show notification
  final androidDetails = AndroidNotificationDetails(
    'wake_alarm_channel',
    'Wake Up Alarms',
    importance: Importance.max,
    priority: Priority.high,
    fullScreenIntent: true,  // Opens app even when locked
    ongoing: true,           // Can't swipe away
    autoCancel: false,
    actions: [
      AndroidNotificationAction('stop', 'Stop'),
      AndroidNotificationAction('snooze', 'Snooze'),
    ],
  );
  
  await _plugin.show(alarmNotificationId, title, body, details);
}
```

### ⚠️ PROBLEMS:

1. **Silent catch blocks** - Alarm sound/vibration failures are swallowed
2. **No retry logic** - If notification fails, user won't wake up
3. **Snooze not implemented** - Action exists but handler is TODO

---

## 3.7 ApiClient - Server Communication

**File:** `lib/services/api_client.dart`
**Lines:** 455

### Bundle ID Mismatch (CRITICAL BUG)

```dart
class ApiClient {
  static const String _bundleId = 'com.example.geowake2';  // ❌ WRONG
  
  Future<Map<String, String>> _getAuthHeaders() async {
    return {
      'Content-Type': 'application/json',
      'X-App-Bundle-Id': _bundleId,  // Sends wrong ID to server
    };
  }
}
```

**Expected:** `com.geowake` (from Android build.gradle)
**Actual:** `com.example.geowake2`

This means the server's auth check should FAIL, unless the server is also misconfigured with the wrong expected ID.

---

# PART 4: COMPLETE ISSUE INVENTORY

## 4.1 🔴 CRITICAL ISSUES (8)

### C1: Bundle ID Mismatch (Security Bypass Risk)
- **Location:** `api_client.dart:15`, `geowake-server/config.js`
- **Impact:** Auth can be bypassed if either side changes independently
- **Fix:** Sync to single source of truth in both codebases

### C2: TrackingService Size (Maintainability Crisis)
- **Location:** `trackingservice.dart` (4,441 lines)
- **Impact:** Impossible to test, modify, or debug safely
- **Fix:** Extract into 4-6 focused files

### C3: Dual State Systems (Race Conditions)
- **Location:** `trackingservice.dart` globals + class fields
- **Impact:** Foreground/background state desync
- **Fix:** Single StateNotifier/Riverpod state

### C4: DevServer Security Exposure
- **Location:** `lib/debug/dev_server.dart`
- **Impact:** Binds 0.0.0.0 with no auth in debug builds
- **Fix:** Compile out in release, add auth token

### C5: Server Auth is Trivially Spoofable
- **Location:** `geowake-server/middleware/auth.js`
- **Impact:** Anyone can send X-App-Bundle-Id header
- **Fix:** Add device fingerprinting, request signing

### C6: 70+ Silent Catch Blocks (UPDATED COUNT)
- **Location:** Throughout codebase - more than originally estimated:
  - `trackingservice.dart`: 21+ instances (lines 112, 337, 370, 377, 454, 475, 489, 527, 557, 565, 604, 641, 670, 701, 710, 847, 851, 862, 872, 879, 884)
  - `transfer_utils.dart`: 4 instances (lines 140, 254, 507, 667)
  - `tracking_state_store.dart`: 4 instances (lines 68, 103, 168, 208)
  - Plus 40+ more in other files and test code
- **Impact:** Errors disappear, bugs hide, impossible to diagnose production issues
- **Fix:** Proper error handling, logging, user feedback

### C7: No Environment Configuration
- **Location:** Hardcoded URLs in multiple files
- **Impact:** Can't deploy to staging without code changes
- **Fix:** Create environment.dart with build flavors

### C8: Memory Leak in SimulationClient
- **Location:** `simulation_client.dart` - WebSocket not cleaned up
- **Impact:** Memory grows during long sessions
- **Fix:** Proper dispose() in all lifecycle hooks

---

## 4.2 🟡 MODERATE ISSUES (15)

### M1: _processPosition is 400+ lines
- Single responsibility violation, extract helpers

### M2: GPS dropout buffer only 25 seconds
- Metro tunnels can be 2+ minutes, needs extension

### M3: No offline alarm capability
- If network fails during tracking, can't alert user

### M4: RouteCache TTL only 5 minutes
- Too aggressive for metro routes that don't change

### M5: No rate limiting on API endpoints
- Server vulnerable to abuse

### M6: Hardcoded vibration patterns
- Can't customize per user preference

### M7: TransitLegStops assumes uniform stop spacing
- Real metro stops are not evenly spaced

### M8: ETA uncertainty (sigmaEta) not used in UI
- Calculated but never displayed to user

### M9: DeviationMonitor not connected to reroute
- Monitors deviation but doesn't trigger reroute

### M10: TestServiceInstance in production code
- Should be in test/ folder only

### M11: No connection state UI in MapTracking
- User doesn't know if GPS is working

### M12: Snooze action not implemented
- Button exists but does nothing

### M13: RecentLocationsService max 15 items
- No LRU eviction, just truncates

### M14: No analytics/crash reporting
- Can't diagnose production issues

### M15: SharedPreferences not encrypted
- Sensitive data (routes, locations) stored plaintext

### M16: setState() calls without mounted checks in some paths (NEW)
- **Location:** Many setState calls in `maptracking.dart`, `homescreen.dart`
- **Positive:** Most have `!mounted` guards, but need audit for completeness
- **Impact:** Potential "setState called after dispose" errors

### M17: Completer patterns without proper cleanup (NEW)
- **Location:** `trackingservice.dart:120` - `_pendingAcks` map
- **Issue:** Completers could leak if never completed/timed out
- **Impact:** Memory leaks in edge cases

---

## 4.3 🟢 MINOR ISSUES (10)

### m1: Magic numbers throughout code
### m2: Inconsistent naming (camelCase vs snake_case in JSON)
### m3: No dartdoc comments on public APIs
### m4: Theme doesn't sync across reinstalls
### m5: TODOs left in code (15+ instances)
### m6: Dead code in transfer_utils.dart
### m7: Duplicate haversine implementations
### m8: No loading skeleton in HomeScreen
### m9: Map tap debounce is 280ms (feels laggy)
### m10: Slider divisions don't match step sizes

---

## 4.4 🟣 NEWLY DISCOVERED ISSUES (From Additional Searches)

### N1: print() Statements in Production Code
- **Location:** `simulation_client.dart` (15+ instances), `main_dashboard.dart` (5+ instances)
- **Impact:** Console spam, potential info leak in release, no structured logging
- **Fix:** Replace with `dev.log()` or remove from production code

### N2: Hardcoded localhost References
- **Location:** `playground_bridge.dart:30` defaults to `ws://127.0.0.1:8081`
- **Impact:** Release builds could try to connect to localhost WebSocket
- **Mitigated:** Disabled by default, but still a code smell

### N3: Many Null Assertion Operators (!.)
- **Location:** 50+ instances in `trackingservice.dart` alone
- **Examples:** Lines 74, 799, 804, 811, 975, 997, 1017, 1042-1058, 1247-1250
- **Impact:** Runtime crashes if state isn't properly initialized
- **Fix:** Use null-aware operators (?.) or proper null checks

### N4: Static Mutable State Without Synchronization
- **Location:** 
  - `TrackingService.isTestMode` (trackingservice.dart:85)
  - `NotificationService.isTestMode` (notification_service.dart:327)
  - `ApiClient.testMode` (api_client.dart:16)
  - `ApiClient.directionsCallCount` (api_client.dart:21)
  - `AlarmPlayer._initialized` (alarm_player.dart:9)
  - `AlarmHaptics._active` (alarm_haptics.dart:13)
- **Impact:** Race conditions if accessed from multiple isolates
- **Fix:** Use proper state management or isolate-safe mechanisms

### N5: Timer Proliferation Without Centralized Management
- **Location:** `trackingservice.dart` has 6+ different Timer instances:
  - `_heartbeatSendTimer` (line 627)
  - `_alarmStopPollTimer` (line 829)
  - `_gpsCheckTimer` (line 2995)
  - `_heartbeatCheckTimer` (line 2724)
  - Plus timers in `simulation_client.dart` and `notification_service.dart`
- **Impact:** Easy to leak timers, complex cancellation logic
- **Fix:** Centralized timer manager or use Stream-based patterns

### N6: Tests Skipped Due to Missing Infrastructure
- **Location:** Multiple test files have `skip: true`:
  - `widget_test.dart:11` - smoke test skipped
  - `maptracking_reroute_refresh_test.dart:7` - empty async body
  - `maptracking_end_tracking_navigation_test.dart:7` - empty async body
- **Impact:** Reduced test coverage, false confidence in CI
- **Fix:** Implement proper Google Maps mocks or remove skipped tests

### N7: Inconsistent kReleaseMode Usage
- **Location:** `api_client.dart` uses `kReleaseMode` at lines 39, 118, 268
- **Issue:** Only in one service, rest of codebase uses `isTestMode` flags
- **Impact:** Debug behavior inconsistent across services
- **Fix:** Standardize on one approach (preferably `kReleaseMode`)

### N8: Unhandled Exceptions in Direction Fetching
- **Location:** `direction_service.dart:194`, `homescreen.dart:779-781`
- **Code:** `throw Exception("Failed to fetch directions: $e")`
- **Impact:** Generic exception loses original stack trace
- **Fix:** Rethrow or use custom exception types with cause

---

# PART 5: HOW COMPONENTS CONNECT

## 5.1 Dependency Graph

```
main.dart
    │
    ├──▶ HomeScreen
    │       ├──▶ PlacesService ──▶ ApiClient
    │       ├──▶ MetroStopService ──▶ ApiClient
    │       ├──▶ OfflineCoordinator ──▶ DirectionService ──▶ ApiClient
    │       ├──▶ TrackingService
    │       ├──▶ TrackingStateStore
    │       └──▶ PermissionService
    │
    ├──▶ MapTrackingScreen
    │       ├──▶ TrackingService (listener)
    │       ├──▶ TrackingStateStore
    │       ├──▶ SimulationClient (playground mode)
    │       └──▶ NotificationService
    │
    └──▶ SettingsDrawer
            └──▶ SharedPreferences (theme, ringtone)

TrackingService (Background)
    ├──▶ Geolocator (position stream)
    ├──▶ EtaEngine
    ├──▶ StopLogicEngine
    ├──▶ SnapToRouteEngine
    ├──▶ RouteRegistry
    ├──▶ ActiveRouteManager
    ├──▶ DeviationMonitor
    ├──▶ GpsHealthMonitor
    ├──▶ SensorFusionManager
    ├──▶ ReroutePolicy
    ├──▶ TransferUtils
    ├──▶ NotificationService
    ├──▶ TrackingStateStore
    └──▶ SimulationClient
```

## 5.2 Data Flow: Position → Alarm

```
Geolocator.getPositionStream()
         │
         ▼
TrackingService._processPosition(Position)
         │
         ├──▶ SnapToRouteEngine.snap() ──▶ progressMeters, offsetMeters
         │
         ├──▶ EtaEngine.computeEta() ──▶ remainingMeters, etaSeconds
         │
         ├──▶ StopLogicEngine.calculateRemainingStops() ──▶ remainingStops
         │
         ├──▶ Alarm Evaluation:
         │    if (mode == 'distance') check remainingMeters <= threshold*1000
         │    if (mode == 'time') check etaSeconds <= threshold*60
         │    if (mode == 'stops') check remainingStops <= threshold
         │
         └──▶ if shouldTrigger && !_alarmFired:
              _triggerAlarm()
                   │
                   ├──▶ Set _alarmFired = true
                   ├──▶ TrackingStateStore.setAlarmFired(true)
                   ├──▶ service.invoke('triggerAlarm', {...})
                   │         │
                   │         ▼ (IPC to foreground)
                   │    MapTrackingScreen receives 'triggerAlarm' event
                   │         │
                   │         ▼
                   │    NotificationService.showWakeUpAlarm()
                   │         │
                   │         ├──▶ AlarmPlayer.playSelected()
                   │         ├──▶ AlarmHaptics.start()
                   │         └──▶ Show fullscreen notification
                   │
                   └──▶ SimulationClient.broadcastState(alarmFired: true)
```

## 5.3 State Persistence Flow

```
User Starts Tracking
         │
         ▼
HomeScreen._proceedWithDirections()
         │
         ├──▶ TrackingStateStore.setActive(true)
         ├──▶ TrackingStateStore.setAlarmFired(false)
         └──▶ TrackingStateStore.saveSnapshot({
                  destinationName, destLat, destLng,
                  alarmMode, alarmValue, metroMode,
                  userLat, userLng, createdAt,
                  directions  // Full API response cached!
              })

App Killed by System
         │
         ▼
(Background service keeps running)
         │
         ▼
App Relaunched
         │
         ▼
SplashScreen.initState()
         │
         ├──▶ TrackingStateStore.isActive() ──▶ true
         ├──▶ TrackingStateStore.loadSnapshot() ──▶ TrackingSnapshot
         │
         └──▶ Navigate directly to MapTrackingScreen with snapshot data
```

---

# PART 6: TESTING COVERAGE ANALYSIS

## 6.1 Test File Inventory

| Test File | Lines | Coverage |
|-----------|-------|----------|
| trackingservice_test.dart | ~800 | 🟡 Partial |
| eta_engine_test.dart | ~400 | ✅ Good |
| stop_logic_engine_test.dart | ~350 | ✅ Good |
| snap_to_route_test.dart | ~200 | ✅ Good |
| deviation_monitor_test.dart | ~150 | ✅ Good |
| transfer_utils_test.dart | ~300 | ✅ Good |
| route_cache_test.dart | ~150 | ✅ Good |
| api_client_test.dart | ~100 | 🟡 Mocked only |

## 6.2 Coverage Gaps

### NOT TESTED:
1. `NotificationService` - No tests (UI dependent)
2. `AlarmPlayer` - No tests (audio dependent)
3. `AlarmHaptics` - No tests (native platform)
4. `HomeScreen` - No widget tests
5. `MapTrackingScreen` - No widget tests
6. `SimulationClient` - WebSocket mocking missing
7. Server-side (`geowake-server/`) - No tests at all

### INTEGRATION TESTS MISSING:
1. Full HomeScreen → MapTracking flow
2. Background service alarm trigger
3. App kill/restore with active tracking
4. Offline mode fallback

---

# PART 7: RECOMMENDATIONS (PRIORITIZED)

## P0: IMMEDIATE (Before Next Release)

1. **Fix Bundle ID Mismatch**
   ```dart
   // api_client.dart
   static const String _bundleId = 'com.geowake';  // Match Android
   ```

2. **Add Error Logging**
   ```dart
   catch (e, stack) {
     dev.log('Error: $e\n$stack', name: 'ComponentName', level: 1000);
     // Don't swallow - at least log!
   }
   ```

3. **Remove DevServer from Release**
   ```dart
   // Only include in debug builds
   if (kDebugMode) {
     DevServer.start();
   }
   ```

## P1: SHORT-TERM (Next Sprint)

4. **Split TrackingService**
   - `tracking_state.dart` - State management
   - `alarm_evaluator.dart` - Threshold checks
   - `route_processor.dart` - Route registration
   - `ipc_handlers.dart` - Service communication

5. **Add Environment Config**
   ```dart
   class Environment {
     static const apiUrl = String.fromEnvironment(
       'API_URL',
       defaultValue: 'https://geowake-production.up.railway.app/api',
     );
   }
   ```

6. **Implement Snooze**
   ```dart
   case 'snooze':
     await AlarmPlayer.stop();
     await AlarmHaptics.stop();
     _scheduleSnoozeAlarm(minutes: 5);
     break;
   ```

## P2: MEDIUM-TERM (Next Month)

7. **Add Server Request Signing**
8. **Implement Widget Tests for Screens**
9. **Add Analytics/Crash Reporting**
10. **Create Offline Alarm Fallback**

## P3: LONG-TERM (Next Quarter)

11. **Migrate State to Riverpod**
12. **Add E2E Integration Tests**
13. **Implement Proper EKF for GPS Fusion**
14. **Add Multi-Language Support**

---

# APPENDIX A: FILE LINE COUNTS

| File | Lines |
|------|-------|
| trackingservice.dart | 4,441 |
| notification_service.dart | 1,495 |
| main_dashboard.dart | 1,358 |
| homescreen.dart | 1,214 |
| maptracking.dart | 1,080 |
| transfer_utils.dart | 689 |
| eta_engine.dart | 476 |
| api_client.dart | 455 |
| direction_service.dart | 423 |
| stop_logic_engine.dart | 408 |
| simulation_client.dart | 351 |
| active_route_manager.dart | 284 |
| tracking_state_store.dart | 230 |
| route_registry.dart | 219 |
| polyline_decoder.dart | 195 |
| metro_stop_service.dart | 178 |
| simulation_engine.dart | 160 |
| route_cache.dart | 148 |
| gps_health_monitor.dart | 144 |
| permission_service.dart | 143 |
| offline_coordinator.dart | 136 |
| sensor_fusion.dart | 125 |
| polyline_simplifier.dart | 122 |
| snap_to_route.dart | 106 |
| **TOTAL** | **~15,500** |

---

*Document Generated: December 24, 2025*
*Analysis: Complete line-by-line review of all 59 source files*
*Methodology: Systematic code reading with cross-reference validation*
