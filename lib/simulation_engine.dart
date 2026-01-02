import 'dart:math';
import 'package:google_maps_flutter/google_maps_flutter.dart';

class SimulationEngine {
  List<LatLng> _route = [];
  int _currentIndex = 0;
  double _progressInSegment = 0.0; // 0.0 to 1.0

  bool isPlaying = false;
  double speedMultiplier = 1.0; // 1x = real time (approx 1.4 m/s walking)
  double noiseAmplitude = 0.0; // meters

  final Random _rng = Random();

  // State
  LatLng? currentPosition;
  double currentHeading = 0.0;

  // Getters
  List<LatLng> get route => _route;
  bool get hasRoute => _route.isNotEmpty;

  // Distance Cache
  List<double> _segmentDistances = [];
  double _totalDistance = 0.0;

  void loadRoute(List<LatLng> route) {
    _route = route;
    _currentIndex = 0;
    _progressInSegment = 0.0;

    // Pre-calculate distances
    _segmentDistances.clear();
    _totalDistance = 0.0;
    if (_route.isNotEmpty) {
      for (int i = 0; i < _route.length - 1; i++) {
        double d = _distance(_route[i], _route[i + 1]);
        _segmentDistances.add(d);
        _totalDistance += d;
      }
      currentPosition = _route.first;
    }
  }

  double get progress {
    if (_route.isEmpty || _totalDistance == 0) return 0.0;

    double covered = 0.0;
    for (int i = 0; i < _currentIndex; i++) {
      covered += _segmentDistances[i];
    }
    if (_currentIndex < _segmentDistances.length) {
      covered += _segmentDistances[_currentIndex] * _progressInSegment;
    }

    return (covered / _totalDistance).clamp(0.0, 1.0);
  }

  void seek(double t) {
    if (_route.isEmpty || _totalDistance == 0) return;

    t = t.clamp(0.0, 1.0);
    double targetDist = t * _totalDistance;

    double currentDist = 0.0;
    for (int i = 0; i < _segmentDistances.length; i++) {
      double segDist = _segmentDistances[i];
      if (currentDist + segDist >= targetDist) {
        // Found the segment
        _currentIndex = i;
        _progressInSegment = (targetDist - currentDist) / segDist;
        currentPosition = _interpolate(
          _route[i],
          _route[i + 1],
          _progressInSegment,
        );
        return;
      }
      currentDist += segDist;
    }

    // If we get here, we are at the end
    _currentIndex = _route.length - 2; // Last segment
    _progressInSegment = 1.0;
    currentPosition = _route.last;
  }

  void update(double dtSeconds) {
    if (!isPlaying || _route.isEmpty || _currentIndex >= _route.length - 1) {
      return;
    }

    // Base walking speed ~1.4 m/s (5 km/h)
    double moveDistance = 1.4 * speedMultiplier * dtSeconds;

    // Get current segment
    // Check bounds
    if (_currentIndex >= _segmentDistances.length) return;

    double segmentDist = _segmentDistances[_currentIndex];

    if (segmentDist == 0) {
      _currentIndex++;
      return;
    }

    // Calculate progress increment
    double progressDelta = moveDistance / segmentDist;
    _progressInSegment += progressDelta;

    // Check if segment complete
    if (_progressInSegment >= 1.0) {
      // Move to next segment
      _currentIndex++;
      _progressInSegment = 0.0;

      // Handle overflow recursively (simple version: just clamp to start of next)
      if (_currentIndex >= _route.length - 1) {
        currentPosition = _route.last;
        isPlaying = false; // End of route
        return;
      }

      // Recalculate for new segment
      currentPosition = _route[_currentIndex];
    } else {
      // Interpolate
      LatLng start = _route[_currentIndex];
      LatLng end = _route[_currentIndex + 1];
      currentPosition = _interpolate(start, end, _progressInSegment);
    }

    // Apply Noise
    if (noiseAmplitude > 0 && currentPosition != null) {
      currentPosition = _applyNoise(currentPosition!, noiseAmplitude);
    }
  }

  LatLng _interpolate(LatLng a, LatLng b, double t) {
    double lat = a.latitude + (b.latitude - a.latitude) * t;
    double lng = a.longitude + (b.longitude - a.longitude) * t;
    return LatLng(lat, lng);
  }

  LatLng _applyNoise(LatLng pos, double meters) {
    // 1 degree lat ~ 111,000 meters
    double latOffset = (_rng.nextDouble() - 0.5) * 2 * (meters / 111000);
    double lngOffset =
        (_rng.nextDouble() - 0.5) *
        2 *
        (meters / (111000 * cos(pos.latitude * pi / 180)));
    return LatLng(pos.latitude + latOffset, pos.longitude + lngOffset);
  }

  double _distance(LatLng a, LatLng b) {
    // Haversine or simple Euclidean for short distances
    // Using simple Euclidean approximation for speed in simulation
    const R = 6371000; // Radius of Earth in meters
    double dLat = (b.latitude - a.latitude) * pi / 180;
    double dLon = (b.longitude - a.longitude) * pi / 180;
    double lat1 = a.latitude * pi / 180;
    double lat2 = b.latitude * pi / 180;

    double x =
        sin(dLat / 2) * sin(dLat / 2) +
        sin(dLon / 2) * sin(dLon / 2) * cos(lat1) * cos(lat2);
    double y = 2 * atan2(sqrt(x), sqrt(1 - x));
    return R * y;
  }
}
