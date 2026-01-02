# Alarm Logic Fix Implementation Plan

## ✅ COMPLETED FIXES

### Issue 1: Priority Order Fixed
**File:** `lib/services/alarm_evaluator.dart`
```
finalDestination (100) > finalStation (90) > transfer (80) > modeChange (70) > preBoarding (60)
```

### Issue 2: preBoarding Skip After First Metro Boarding
**File:** `lib/services/alarm_evaluator.dart`
- Added `hasPassedMetroLeg` check
- preBoarding events are skipped if user has already entered any metro leg

### Issue 3: Interchange Walk Detection
**File:** `lib/services/tracking/alarm_controller.dart`
- `isMetroLeg` now returns `true` during interchange walks between metro legs
- Logic: If user has entered a metro leg but hasn't passed the last metro leg end, they're in transit journey context

### Issue 4: Zero-Stop Express Fixed
**File:** `lib/services/alarm_evaluator.dart`
- Changed from broken distance-based fallback (`userValue * 1000`) to immediate fire
- Now fires immediately when user enters a zero-stop express leg
- Reason: "zero_stop_express_immediate"
- Message: "Next stop: $label (express)"

### Issue 5: Dashboard Pin Rework
**File:** `lib/main_dashboard.dart`
- Added `_gtfsStopMarkers` layer for grey pins at all GTFS stops
- Added `_activeTransitLegs` to receive metro leg info
- Updated `_buildAlarmTriggerMarkers` to compute 60% rule for non-metro legs
- Updated `_syncMarkers` to include GTFS stop layer

**Files:** `lib/services/simulation_client.dart`, `lib/services/location_manager.dart`, `lib/services/route_session_manager.dart`
- Added `transitLegs` parameter to `broadcastRoute`
- Serialize `TransitLegStops` to JSON for dashboard consumption

---

## 📋 PIN VISUALIZATION (Dashboard)

| Pin Color | Purpose | Z-Index |
|-----------|---------|---------|
| Grey | All GTFS stops along polyline | 1 (bottom) |
| Red | Start, destination, switchpoints | 2-3 |
| Yellow | Expected alarm trigger point (next) | 6 |
| Blue | Current user location | 10 (top) |

### Alarm Trigger Calculation
- **Metro legs (stops mode):** Yellow pin at stop position N stops before event
- **Non-metro legs:** Yellow pin at 40% traveled point (60% remaining = trigger)
- **Time mode:** Yellow pin at event position (actual trigger depends on ETA)

---

## ✅ TEST COVERAGE

### New Test Cases Added
**File:** `test/alarm_evaluator_test.dart`

| Test Group | Tests | Purpose |
|------------|-------|---------|
| Priority Order | 2 | Verify finalDestination > finalStation > transfer > preBoarding |
| preBoarding Skip After Metro | 2 | Verify preBoarding only fires before first metro boarding |
| Zero-Stop Express | 2 | Verify immediate fire on zero-stop express legs |

### Test Results
```
flutter test test/alarm_evaluator_test.dart --reporter compact
00:01 +19: All tests passed!

flutter test --reporter compact
00:21 +205 ~3: All tests passed!
```

### Key Scenarios Covered
1. **Priority chain verification** - finalStation beats transfer beats preBoarding
2. **Interchange walk handling** - No preBoarding during platform transfers
3. **Zero-stop express** - Fires immediately when entering leg with 0 intermediate stops
4. **60% rule for non-metro legs** - Fires at 40% traveled, 60% remaining

---
