import 'dart:math';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:developer' as dev;

/// ETA Engine - Computes estimated time of arrival using map-matching,
/// speed smoothing, dwell time handling, and uncertainty calculations.
class EtaEngine {
  // Configuration (tunable)
  static const double vMin = 0.5; // m/s - minimum effective speed
  static const double speedAlpha = 0.25; // exponential smoothing alpha
  static const double gpsAccuracyThreshold = 30.0; // meters
  static const double stopSpeedThreshold = 0.7; // m/s
  static const int stopTimeThresholdMs = 8000; // ms (8s)
  static const double defaultDwellSeconds = 25.0; // seconds
  static const double uncertaintyMinPos = 8.0; // meters fallback
  static const double sigmaVDefault = 1.5; // m/s fallback
  static const double largeSigmaEta = 1e6; // huge uncertainty when v ≈ 0
  static const int speedWindowMax = 10; // last N speeds for sigma_v
  static const double maxSnapDistance =
      100.0; // meters - max snap search radius

  // State (persisted between updates)
  double? smoothedSpeed;
  Position? lastGps;
  DateTime? stoppedSince;
  List<double> speedWindow = [];
  LatLng? lastSnappedPoint;
  int? lastSegmentIndex; // Optimization: limiting search window
  double? lastSigma;

  EtaEngine();

  /// Initialize from persisted state
  Future<void> loadState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      smoothedSpeed = prefs.getDouble('eta_smoothed_speed');
      final windowJson = prefs.getStringList('eta_speed_window');
      if (windowJson != null) {
        speedWindow = windowJson.map((e) => double.parse(e)).toList();
      }
    } catch (e) {
      dev.log('EtaEngine: Failed to load state: $e', name: 'EtaEngine');
    }
  }

  DateTime? _lastSaveTime;
  static const Duration _saveThrottle = Duration(seconds: 15);

  /// Persist state to SharedPreferences
  /// [force] bypasses the throttle (e.g. on service stop)
  Future<void> saveState({bool force = false}) async {
    final now = DateTime.now();
    if (!force &&
        _lastSaveTime != null &&
        now.difference(_lastSaveTime!) < _saveThrottle) {
      return;
    }
    _lastSaveTime = now;

    try {
      final prefs = await SharedPreferences.getInstance();
      if (smoothedSpeed != null) {
        await prefs.setDouble('eta_smoothed_speed', smoothedSpeed!);
      }
      await prefs.setStringList(
        'eta_speed_window',
        speedWindow.map((e) => e.toString()).toList(),
      );
    } catch (e) {
      dev.log('EtaEngine: Failed to save state: $e', name: 'EtaEngine');
    }
  }

  /// Project a point onto a line segment and return the closest point + fraction
  LatLng _projectPointOnSegment(LatLng point, LatLng segStart, LatLng segEnd) {
    final dx = segEnd.longitude - segStart.longitude;
    final dy = segEnd.latitude - segStart.latitude;
    final t =
        ((point.longitude - segStart.longitude) * dx +
            (point.latitude - segStart.latitude) * dy) /
        (dx * dx + dy * dy);

    final tClamped = t.clamp(0.0, 1.0);
    return LatLng(
      segStart.latitude + tClamped * dy,
      segStart.longitude + tClamped * dx,
    );
  }

  /// Map-match current GPS to route polyline and compute distance remaining
  ({double remainingMeters, LatLng snapped}) matchToRoute(
    List<LatLng> routeCoords,
    LatLng currentPoint,
  ) {
    if (routeCoords.isEmpty) {
      return (remainingMeters: 0.0, snapped: currentPoint);
    }

    double minDist = double.infinity;
    LatLng? bestSnapped;
    int bestSegmentIndex = 0;
    double bestFraction = 0.0;

    // Optimization: Define search window if we have a previous valid match
    int startIndex = 0;
    int endIndex = routeCoords.length - 1;
    bool usingWindow = false;

    if (lastSegmentIndex != null && lastSnappedPoint != null) {
      // Search +/- 50 segments around last known position (approx 1-2km window depending on density)
      // This makes the search O(1) for long routes.
      const int windowSize = 50;
      startIndex = max(0, lastSegmentIndex! - windowSize);
      endIndex = min(routeCoords.length - 1, lastSegmentIndex! + windowSize);

      // Safety check: if we are too far from last snap, force full search
      final distToLast = Geolocator.distanceBetween(
        currentPoint.latitude,
        currentPoint.longitude,
        lastSnappedPoint!.latitude,
        lastSnappedPoint!.longitude,
      );
      if (distToLast > 2000) {
        // If jumped > 2km, assume context loss
        startIndex = 0;
        endIndex = routeCoords.length - 1;
      } else {
        usingWindow = true;
      }
    }

    // Find closest segment within window
    // IMPORTANT: loop limit is 'i < endIndex' because segments are [i, i+1]
    for (int i = startIndex; i < endIndex; i++) {
      final segStart = routeCoords[i];
      final segEnd = routeCoords[i + 1];

      // Optimization: Rough bounding box check before expensive geodesic distance?
      // Maybe overkill for Dart, but simple lattice distance check is cheaper.
      // Skipping for now to keep code clean; windowing is the big win.

      final projected = _projectPointOnSegment(currentPoint, segStart, segEnd);
      final dist = Geolocator.distanceBetween(
        currentPoint.latitude,
        currentPoint.longitude,
        projected.latitude,
        projected.longitude,
      );

      // Snap safety: skip segments too far from last known position (if context exists)
      if (lastSnappedPoint != null) {
        final distToSegStart = Geolocator.distanceBetween(
          lastSnappedPoint!.latitude,
          lastSnappedPoint!.longitude,
          segStart.latitude,
          segStart.longitude,
        );
        if (distToSegStart > maxSnapDistance * 20 && !usingWindow) {
          // *20 relax factor: if full search, don't be too aggressive in skipping,
          // relying on windowing is better. Original code had *2 which is very tight.
          // In windowed mode, we trust the window.
          continue;
        }
      }

      if (dist < minDist) {
        minDist = dist;
        bestSnapped = projected;
        bestSegmentIndex = i;
        // Calculate fraction within this segment
        final segDist = Geolocator.distanceBetween(
          segStart.latitude,
          segStart.longitude,
          segEnd.latitude,
          segEnd.longitude,
        );
        final projDist = Geolocator.distanceBetween(
          segStart.latitude,
          segStart.longitude,
          projected.latitude,
          projected.longitude,
        );
        bestFraction = segDist > 0 ? projDist / segDist : 0.0;
      }
    }

    // Fallback: If window search failed to find a reasonable snap (e.g. off-route or jumped outside window),
    // try full search if we weren't already doing it.
    if (usingWindow && minDist > maxSnapDistance) {
      // Reset and do full search
      startIndex = 0;
      endIndex = routeCoords.length - 1;
      // ... Duplicate loop logic or refactor?
      // For simplicity, just re-run the loop range.
      for (int i = 0; i < routeCoords.length - 1; i++) {
        // Simplified loop for fallback
        final segStart = routeCoords[i];
        final segEnd = routeCoords[i + 1];
        final projected = _projectPointOnSegment(
          currentPoint,
          segStart,
          segEnd,
        );
        final dist = Geolocator.distanceBetween(
          currentPoint.latitude,
          currentPoint.longitude,
          projected.latitude,
          projected.longitude,
        );
        if (dist < minDist) {
          minDist = dist;
          bestSnapped = projected;
          bestSegmentIndex = i;
          final segDist = Geolocator.distanceBetween(
            segStart.latitude,
            segStart.longitude,
            segEnd.latitude,
            segEnd.longitude,
          );
          final projDist = Geolocator.distanceBetween(
            segStart.latitude,
            segStart.longitude,
            projected.latitude,
            projected.longitude,
          );
          bestFraction = segDist > 0 ? projDist / segDist : 0.0;
        }
      }
    }

    if (bestSnapped == null) {
      // Vertex Fallback
      for (int i = 0; i < routeCoords.length; i++) {
        final dist = Geolocator.distanceBetween(
          currentPoint.latitude,
          currentPoint.longitude,
          routeCoords[i].latitude,
          routeCoords[i].longitude,
        );
        if (dist < minDist) {
          minDist = dist;
          bestSnapped = routeCoords[i];
          bestSegmentIndex = i;
          bestFraction = i == routeCoords.length - 1 ? 1.0 : 0.0;
        }
      }
    }

    lastSnappedPoint = bestSnapped ?? currentPoint;
    lastSegmentIndex = bestSegmentIndex; // Persist index for next update

    // Compute remaining distance from snapped point to end
    double remaining = 0.0;

    // Add fraction of current segment
    if (bestSegmentIndex < routeCoords.length - 1) {
      final segStart = routeCoords[bestSegmentIndex];
      final segEnd = routeCoords[bestSegmentIndex + 1];
      final segDist = Geolocator.distanceBetween(
        segStart.latitude,
        segStart.longitude,
        segEnd.latitude,
        segEnd.longitude,
      );
      remaining += segDist * (1.0 - bestFraction);
    }

    // Add all remaining segments
    for (int i = bestSegmentIndex + 1; i < routeCoords.length - 1; i++) {
      remaining += Geolocator.distanceBetween(
        routeCoords[i].latitude,
        routeCoords[i].longitude,
        routeCoords[i + 1].latitude,
        routeCoords[i + 1].longitude,
      );
    }

    return (remainingMeters: remaining, snapped: bestSnapped ?? currentPoint);
  }

  /// Update smoothed speed with exponential smoothing
  double _updateSmoothedSpeed(double rawSpeed) {
    if (rawSpeed.isNaN || rawSpeed.isInfinite) {
      return smoothedSpeed ?? 0.0;
    }

    if (smoothedSpeed == null) {
      smoothedSpeed = rawSpeed;
    } else {
      smoothedSpeed = speedAlpha * rawSpeed + (1 - speedAlpha) * smoothedSpeed!;
    }

    // Maintain speed window for sigma_v
    speedWindow.add(smoothedSpeed!);
    if (speedWindow.length > speedWindowMax) {
      speedWindow.removeAt(0);
    }

    return smoothedSpeed!;
  }

  /// Compute sigma_v (speed uncertainty) from speed window
  double _computeSigmaV() {
    if (speedWindow.length < 2) return sigmaVDefault;

    final mean = speedWindow.reduce((a, b) => a + b) / speedWindow.length;
    final variance =
        speedWindow.map((v) => pow(v - mean, 2)).reduce((a, b) => a + b) /
        (speedWindow.length - 1);
    return sqrt(variance);
  }

  /// Estimate speed from last known GPS if current speed is unavailable
  double _estimateSpeedFromLast(Position gps) {
    if (lastGps == null) {
      lastGps = gps;
      return 0.0;
    }

    final dt = max(
      0.001,
      gps.timestamp.difference(lastGps!.timestamp).inMilliseconds / 1000.0,
    );
    final dist = Geolocator.distanceBetween(
      lastGps!.latitude,
      lastGps!.longitude,
      gps.latitude,
      gps.longitude,
    );
    lastGps = gps;
    return dist / dt;
  }

  ({
    double etaSeconds,
    double remainingMeters,
    double vEst,
    double sigmaEta,
    double dwellAddedSeconds,
    LatLng snappedPoint,
  })
  computeEta({
    required List<LatLng> routeCoords,
    required Position gps,
    bool isMetroMode = false,
    List<double>? stepBoundsMeters,
    List<int>? stepDurationsSeconds,
    double? totalRouteMeters,
  }) {
    final currentPoint = LatLng(gps.latitude, gps.longitude);

    // 1) Map-match and compute distance remaining
    final match = matchToRoute(routeCoords, currentPoint);
    final remainingMeters = match.remainingMeters;
    final snapped = match.snapped;

    // 2) Compute raw speed
    final rawSpeed = gps.speed > 0 ? gps.speed : _estimateSpeedFromLast(gps);
    final vEst = max(_updateSmoothedSpeed(rawSpeed), 0.0);

    // 3) Stop/dwell detection
    double dwellAdd = 0.0;
    // Disable dwell detection in Metro Mode (stops in tunnels != traffic delay)
    if (!isMetroMode) {
      if (rawSpeed < stopSpeedThreshold) {
        stoppedSince ??= gps.timestamp;
      } else {
        stoppedSince = null;
      }

      if (stoppedSince != null &&
          gps.timestamp.difference(stoppedSince!).inMilliseconds >=
              stopTimeThresholdMs) {
        dwellAdd = defaultDwellSeconds;
      }
    }

    // 4) Physics ETA (Base calculation)
    double effectiveSpeed = max(vEst, vMin);
    if (isMetroMode) {
      // Clamp effective speed in Metro Mode to avoid infinite ETAs in tunnels/stops.
      // 5.0 m/s (~18 km/h) is a conservative average for metro systems including stops.
      // FIX: Only apply this clamp if we are moving faster than walking speed (> 2.5 m/s).
      // This prevents the ETA from being artificially short (and triggering alarms)
      // when the user is simply walking to the station at the start of the route.
      if (effectiveSpeed > 2.5) {
        effectiveSpeed = max(effectiveSpeed, 5.0);
      }
    }
    double etaSeconds = remainingMeters / effectiveSpeed;
    etaSeconds += dwellAdd;

    // 5) Smart ETA (Segment-based)
    // If we have step boundaries and durations, we can provide a much better estimate
    // by using the current speed ONLY for the current step, and using the planned/static
    // duration for future steps. This solves the "walking to the train" optimistic ETA bug.
    if (stepBoundsMeters != null &&
        stepDurationsSeconds != null &&
        totalRouteMeters != null &&
        stepBoundsMeters.length == stepDurationsSeconds.length) {
      double accumulatedProgress = totalRouteMeters - remainingMeters;
      // Clamp negative progress (snapping overlap)
      accumulatedProgress = max(0.0, accumulatedProgress);

      int currentStepIndex = -1;
      for (int i = 0; i < stepBoundsMeters.length; i++) {
        if (stepBoundsMeters[i] >= accumulatedProgress) {
          currentStepIndex = i;
          break;
        }
      }

      if (currentStepIndex != -1) {
        // Calculate remaining distance in CURRENT step
        double stepEnd = stepBoundsMeters[currentStepIndex];
        double distRemainingInStep = stepEnd - accumulatedProgress;

        // Time to finish current step at CURRENT effective speed
        double timeForCurrentStep = distRemainingInStep / effectiveSpeed;

        // Time for FUTURE steps (sum of their nominal durations)
        double timeForFutureSteps = 0.0;
        for (
          int k = currentStepIndex + 1;
          k < stepDurationsSeconds.length;
          k++
        ) {
          timeForFutureSteps += stepDurationsSeconds[k];
        }

        // Combine
        etaSeconds = timeForCurrentStep + timeForFutureSteps + dwellAdd;
      }
    }

    // 6) Uncertainty sigma_eta
    final sigmaP = max(gps.accuracy, uncertaintyMinPos);
    final sigmaV = _computeSigmaV();
    double sigmaEta;

    if (effectiveSpeed <= 0.1) {
      sigmaEta = largeSigmaEta;
    } else {
      final termPos = pow(sigmaP / effectiveSpeed, 2);
      final termV = pow((remainingMeters * sigmaV) / pow(effectiveSpeed, 2), 2);
      sigmaEta = sqrt(termPos + termV);
    }

    lastSigma = sigmaEta;

    // Save state asynchronously
    saveState();

    return (
      etaSeconds: etaSeconds,
      remainingMeters: remainingMeters,
      vEst: effectiveSpeed,
      sigmaEta: sigmaEta,
      dwellAddedSeconds: dwellAdd,
      snappedPoint: snapped,
    );
  }

  /// Reset engine state
  void reset() {
    smoothedSpeed = null;
    lastGps = null;
    stoppedSince = null;
    speedWindow.clear();
    lastSnappedPoint = null;
  }
}
