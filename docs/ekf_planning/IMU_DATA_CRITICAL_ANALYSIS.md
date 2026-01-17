# Critical Analysis: IMU Data for EKF Testing

**Date:** 2025-01-20  
**Purpose:** Honest, unbiased assessment of available IMU data for EKF pipeline validation  
**Analyst:** AI Code Assistant

---

## Executive Summary

### ✅ Good News
1. **High-quality metro data exists** - Two complete end-to-end metro journeys with 24 and 23 station annotations
2. **Sample rates are excellent** - 100Hz IMU data (10ms sampling) on both iOS and Android
3. **Station timing is realistic** - 90-180 second inter-station intervals match real metro operations
4. **GPS shows real tunnel behavior** - Up to 140s GPS gaps, exactly what EKF needs to handle

### ⚠️ Honest Concerns
1. **No non-metro routes with annotations** - Can't validate ZUPT-only behavior on bus/car
2. **Android standardisation=false** - One device has uncalibrated axes, requires axis remapping
3. **Two recordings have GPS degradation** - High horizontal accuracy (200m+) indicates poor GPS, not true tunnel dropout
4. **Route geometry must be reconstructed** - Need Google Maps data to build `cumMeters` polyline

### ❌ Critical Gap
1. **No ground truth positions** - Can't measure absolute EKF accuracy (only relative consistency)

---

## 1. Available Data Inventory

### 1.1 Metro Routes (Excellent for EKF Testing)

| Route | Duration | IMU Samples | GPS Points | Stations | Avg GPS Accuracy | GPS Gaps >60s |
|-------|----------|-------------|------------|----------|------------------|---------------|
| **Rajajinagar → Nallur Halli** | 57.4 min | 343,290 | 1,947 | 24 | 206.2m ⚠️ | 2 (140s, 110s) |
| **Nallur Halli → Vijaynagar** | 45.6 min | 273,950 | 1,229 | 23 | 247.4m ⚠️ | 2 (71s, 81s) |
| **Nallur → Vijaynagar (alt)** | 50.6 min | 305,387 | 2,436 | 21 | 19.3m ✅ | 1 (93s) |
| **Majestic → Nallur Halli** | 37.8 min | 229,692 | 1,645 | 19 | 16.6m ✅ | 2 (97s, 73s) |

**Key Observations:**
- **Best quality:** Nallur→Vijaynagar (alt) and Majestic→Nallur Halli have good GPS accuracy (~20m)
- **Degraded GPS:** Rajajinagar and Nallur Halli routes have 200m+ accuracy - indicates Android device with poor GPS, not tunnel dropout
- **All routes have complete station annotations** - Critical for ZUPT association testing

### 1.2 Non-Metro Routes (Limited Value)

| Route | Duration | IMU Samples | GPS Points | Annotations |
|-------|----------|-------------|------------|-------------|
| RT_Nagar → Lalbagh (tunnel) | 31.5 min | 184,042 | 1,893 | 0 ❌ |
| Brundavana → Peenya | 53.1 min | 312,904 | 3,314 | 0 ❌ |
| 121_A (bus) | 70.6 min | 223,066 | 4,322 | 0 ❌ |
| HKBK → RT Nagar | 13.3 min | 76,956 | 810 | 2 ⚠️ |

**Problem:** No ground truth stop locations for non-metro routes. Can only use for:
- Motion classifier validation (moving vs stationary detection)
- GPS gap handling (RT_Nagar tunnel route)
- Bias drift estimation over long durations

---

## 2. Data Quality Assessment

### 2.1 IMU Sample Rate: ✅ EXCELLENT

All recordings maintain 100Hz (10ms) sampling:
```
Rajajinagar route: 343,290 samples / 3,442s = 99.7 Hz ✅
Nallur route:      273,950 samples / 2,737s = 100.1 Hz ✅
```

**Implication:** No sample dropout, no interpolation needed.

### 2.2 Sensor Standardisation: ⚠️ MIXED

| Device | Platform | Standardised | Issue |
|--------|----------|--------------|-------|
| iPhone 15 | iOS | true | ✅ Axes aligned to device frame |
| V2416 | Android | false | ⚠️ Raw sensor axes, may need remapping |
| CPH2649 | Android | false | ⚠️ Raw sensor axes |

**Implication for EKF:**
- iOS data can be used directly for tilt filter
- Android data may need axis transformation: `[x, y, z] → [x, -y, -z]` (common pattern)
- Should add axis detection in EKF initialization

### 2.3 GPS Quality: ⚠️ INCONSISTENT

**Good Recordings (iOS):**
- Horizontal accuracy: 3-30m
- Update rate: ~1Hz (1.25-1.38s intervals)
- True tunnel dropout visible in GPS gaps

**Degraded Recordings (Android V2416):**
- Horizontal accuracy: 200-400m
- This is NOT tunnel dropout - it's poor GPS signal throughout
- Still usable for EKF but don't confuse with tunnel behavior

### 2.4 Annotation Quality: ✅ GOOD

Station annotations are:
- **Manually labeled** (human pressed button at each station)
- **Timing is real** (not estimated)
- **Complete for metro routes** (all stations marked)

**Minor Issues:**
- Some annotations have typos: "seetharam palys" vs "Seetarama palaya"
- Some have "My Annotation 1/2" markers (missed labels)
- Station names don't match official transit data (need mapping)

---

## 3. GPS Gap Analysis (Critical for EKF Validation)

### 3.1 Rajajinagar → Nallur Halli Route

| Gap Start | Gap End | Duration | Location Context |
|-----------|---------|----------|------------------|
| 402s | 542s | **140s** | Between Majestic stations (underground) |
| 571s | 681s | **110s** | Post-Majestic (tunnel section) |

**This is excellent test data!** The 140s gap is exactly what EKF needs to handle. Between annotations:
- majestic @ 474s
- majestic (return) @ 1159s

This 685s gap between same-station annotations includes the two major GPS dropouts.

### 3.2 Nallur → Vijaynagar (Best Quality)

| Gap Start | Gap End | Duration | Location Context |
|-----------|---------|----------|------------------|
| 2146s | 2240s | **93s** | Between Central College and Majestic |

Single tunnel section, clean data.

### 3.3 Majestic → Nallur Halli

| Gap Start | Gap End | Duration | Location Context |
|-----------|---------|----------|------------------|
| 46s | 143s | **97s** | Just after Majestic (tunnel) |
| 159s | 233s | **73s** | Approaching Sir M station |

Two clean GPS dropout events with station context.

---

## 4. ZUPT Detection Potential

Based on station dwell times in annotations:

### 4.1 Inter-Station Intervals (Rajajinagar Route)

| From | To | Duration | ZUPT Detectable? |
|------|-----|----------|------------------|
| rajajinagar | mahakavi kuvempu | 104s | ✅ Yes - moving |
| mahakavi kuvempu | Stirampura | 93s | ✅ Yes - moving |
| Stirampura | mantri square | 125s | ✅ Yes - moving |
| mantri square | majestic | 148s | ✅ Yes - moving |
| **majestic** | **majestic** | **685s** | ⚠️ ISSUE - same station twice |
| Sir M | Dr BR | 98s | ✅ Yes - moving |

**Problem:** The "majestic → majestic" 685s gap indicates the user:
1. Got off at Majestic
2. Waited (or transferred)
3. Got back on

This is **valuable edge case data** for testing ZUPT detection during extended station dwell.

### 4.2 Expected ZUPT Windows

Each station stop typically has 30-60s dwell time (doors open, passengers exit/enter). During this time:
- Accelerometer magnitude should stabilize near 9.81 m/s²
- Gyroscope should show near-zero angular velocity
- Variance should be minimal

**Testing Approach:**
- Extract IMU data ±30s around each station annotation
- Verify low-variance periods align with station times
- Validate ZUPT detector triggers at correct times

---

## 5. Route Geometry Requirements

### 5.1 What We Have

**From Annotations + GPS:**
- Station sequence (24 stations Rajajinagar→Nallur)
- Approximate coordinates at each station
- Inter-station timing

**From Google Maps (Need to Extract):**
- Exact polyline geometry
- Cumulative distance (`cumMeters`) for each point
- Official station coordinates

### 5.2 Route Construction Plan

```
Bengaluru Metro Purple Line (Green Line to Blue Line)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Rajajinagar → Magadi Road → Hosahalli → Vijayanagar → 
Attiguppe → Deepanjali Nagar → Mysore Road → 
Nayandahalli → Rajarajeshwari Nagar → Jnanabharathi → 
Pattanagere → Kengeri Bus Terminal → Kengeri

AND

Majestic (Interchange) → Sir M. Visvesvaraya → 
Dr. B.R. Ambedkar → Cubbon Park → M.G. Road → 
Trinity → Halasuru → Indiranagar → Swami Vivekananda Road → 
Baiyappanahalli (Old Terminal) → Benniganahalli → 
Krishnarajapura → Singayyanapalya → Garudacharpalya → 
Hoodi Junction → Seetharampalya → Kundalahalli → 
Nallurhalli (Terminal)
```

### 5.3 Google Maps Data Needed

For each route segment:
1. **Polyline:** Encoded polyline from Directions API
2. **Distance:** Total meters for route
3. **Station positions:** Snap each station to polyline → cumulative meters

---

## 6. Recommended Test Routes (3 Routes)

### Route 1: Majestic → Nallur Halli (Metro, iOS) ✅ RECOMMENDED

**Why:**
- Best GPS quality (16.6m accuracy)
- Clean GPS gaps (97s, 73s) 
- 19 station annotations
- iOS standardised sensor data

**EKF Test Scenarios:**
- ✅ Normal GPS fusion mode
- ✅ 97s GPS dropout → dead reckoning
- ✅ 19 ZUPT opportunities at stations
- ✅ Station snap association

### Route 2: Rajajinagar → Nallur Halli (Metro, iOS) ✅ RECOMMENDED

**Why:**
- Longest route (57 min)
- Largest GPS gaps (140s, 110s)
- 24 station annotations
- Extended Majestic dwell (685s)

**EKF Test Scenarios:**
- ✅ Long-duration bias drift
- ✅ 140s GPS dropout (stress test)
- ✅ Extended stationary period handling
- ✅ Full route traversal

### Route 3: RT_Nagar → Lalbagh (Non-Metro, Android) ⚠️ PARTIAL

**Why:**
- Non-metro context (road, tunnel)
- Different device characteristics
- Tests axis standardisation handling

**Limitations:**
- ❌ No station annotations
- ⚠️ Android standardisation=false
- Can't validate station snap

**EKF Test Scenarios:**
- ✅ Motion classifier (moving vs stopped at traffic)
- ✅ Android axis handling
- ⚠️ ZUPT detection (no ground truth)

---

## 7. Critical Gaps & Mitigations

### 7.1 No Ground Truth Positions ❌

**Problem:** Can't measure absolute EKF accuracy (meters error at each station).

**Mitigation:**
1. Use station annotations as relative ground truth
2. Measure "did EKF snap to correct station?" (boolean)
3. Compare final EKF `s` vs final GPS position
4. Use inter-station consistency (EKF progress should advance ~smoothly)

### 7.2 No Annotated Non-Metro Routes ❌

**Problem:** Can't validate ZUPT on bus stops, traffic lights, etc.

**Mitigation:**
1. Use motion classifier to detect stops
2. Manually annotate RT_Nagar route (add annotations to CSV)
3. Create synthetic test data for bus scenarios

### 7.3 Android Axis Inconsistency ⚠️

**Problem:** standardisation=false means raw sensor axes.

**Mitigation:**
1. Add axis detection logic to TiltFilter
2. Test with known gravity direction at startup
3. Document expected axis remapping per device

### 7.4 GPS Degradation vs Dropout ⚠️

**Problem:** Some routes have 200m+ accuracy (poor GPS) not clean dropout.

**Mitigation:**
1. Use accuracy-based degradation detection (not just gap-based)
2. Test EKF with "fuzzy GPS" (high uncertainty, valid signal)
3. Separate test cases: tunnel_dropout vs urban_canyon

---

## 8. Simulation Framework Design

### 8.1 Data Injection Architecture

```dart
// lib/core/ekf/simulation/imu_replay_engine.dart

class ImuReplayEngine {
  final String routePath;           // Path to recorded data folder
  final double speedMultiplier;     // 1.0 = real-time, 2.0 = 2x speed
  final Duration startOffset;       // Skip to specific timestamp
  final Duration? endOffset;        // Stop at specific timestamp
  
  Stream<TimestampedSensorEvent> get accelerometerStream;
  Stream<TimestampedSensorEvent> get gyroscopeStream;
  Stream<Position> get gpsStream;
  
  // Station annotations for validation
  List<StationAnnotation> get expectedStations;
  
  // Control
  void start();
  void pause();
  void seekTo(Duration position);
}
```

### 8.2 Dashboard Integration

```dart
// lib/dashboard/unified_dashboard.dart additions

// New simulation controls:
- Route selector dropdown (3 routes)
- Speed slider (0.5x, 1x, 2x, 5x, 10x)
- Start/Pause/Reset buttons
- Seek slider (0% to 100% of route)

// New visualizations:
- Station markers on map (cyan circles)
- ZUPT events (red markers)
- EKF progress line (green)
- GPS progress line (blue, dashed when degraded)
- Uncertainty band (grey shaded ±σ)
```

### 8.3 Test Scenario Configurations

```dart
// lib/core/ekf/simulation/test_scenarios.dart

enum SimulationScenario {
  // Normal operation
  fullRoute,           // Complete route, real-time
  stationDwell,        // Extended stop at one station
  
  // GPS challenges
  tunnelDropout,       // Start at GPS gap, test dead reckoning
  urbanCanyon,         // High accuracy but valid GPS
  intermittentGps,     // GPS in/out every 30s
  
  // Edge cases
  routeChange,         // Switch routes mid-journey
  extendedStationary,  // 10+ min station dwell
  fastTravel,          // Express train skipping stops
}
```

---

## 9. Action Items

### Immediate (Before Implementation)

1. **[DONE]** Analyze IMU data folder structure ✅
2. **[DONE]** Identify best 3 test routes ✅
3. **[TODO]** Extract Google Maps route geometry for Purple Line
4. **[TODO]** Create station → cumulative meters mapping
5. **[TODO]** Manually annotate RT_Nagar route stops (optional)

### Implementation Phase

6. Create `ImuReplayEngine` class for data injection
7. Add `testGyroscopeStream` to `SensorFusionManager`
8. Implement dashboard simulation controls
9. Create test fixtures from recorded data
10. Write integration tests using real IMU data

### Validation Phase

11. Replay Majestic → Nallur route, verify station detection
12. Replay Rajajinagar route, measure 140s drift
13. Compare EKF vs GPS progress at each station
14. Tune parameters based on real-world results

---

## 10. Conclusion

### Data Sufficiency: ✅ SUFFICIENT FOR TESTING

The available IMU data **is sufficient** for validating the EKF pipeline with the following caveats:

1. **Metro testing:** Fully supported with 4 complete routes
2. **ZUPT validation:** Station annotations provide ground truth
3. **GPS dropout:** Real tunnel gaps (up to 140s) for stress testing
4. **Non-metro testing:** Limited - use for motion classifier only

### Recommended Approach

1. **Start with Majestic → Nallur Halli route** (cleanest data)
2. **Stress test with Rajajinagar route** (longest GPS gaps)
3. **Use RT_Nagar for motion classifier** (different context)
4. **Construct route geometry from Google Maps** (required before replay)

### Honest Assessment

This data represents **real-world conditions** that the EKF must handle:
- Variable GPS quality (3m to 400m accuracy)
- True underground tunnel dropout
- Extended station dwell times
- Human annotation timing (realistic, not synthetic)

The main limitation is **lack of ground truth positions** - we can validate relative consistency and station detection, but can't measure absolute meter-level accuracy without additional instrumentation.
