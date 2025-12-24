// lib/services/gps_health_monitor.dart
import 'dart:async';
import 'package:geolocator/geolocator.dart';
import 'dart:developer' as dev;

/// GPS Health States following the architecture spec.
/// 
/// - [healthy]: GPS updates arriving regularly with good accuracy
/// - [degraded]: GPS updates arriving but with poor accuracy or intermittent gaps
/// - [unavailable]: GPS has been silent beyond the unavailable threshold
enum GpsHealthState { healthy, degraded, unavailable }

/// Monitors GPS health to determine when EKF/route-based fallback should activate.
/// 
/// This is a pure observation layer - it does NOT trigger any behavioral changes.
/// The consumer (TrackingService) decides what to do based on the state.
/// 
/// Conservative thresholds (matching existing gpsDropoutBuffer of 25s):
/// - degraded: GPS silent for 10+ seconds OR accuracy > 50m
/// - unavailable: GPS silent for 25+ seconds
class GpsHealthMonitor {
  // Conservative thresholds to avoid false positives
  static const Duration degradedThreshold = Duration(seconds: 10);
  static const Duration unavailableThreshold = Duration(seconds: 25);
  static const double poorAccuracyMeters = 50.0;
  
  // Require sustained degradation before transitioning
  static const Duration sustainedDegradationRequired = Duration(seconds: 5);
  
  GpsHealthState _currentState = GpsHealthState.healthy;
  DateTime? _lastGpsUpdate;
  DateTime? _degradedSince;
  double? _lastAccuracy;
  
  final StreamController<GpsHealthState> _stateController =
      StreamController<GpsHealthState>.broadcast();
  
  /// Current health state (synchronous access)
  GpsHealthState get currentState => _currentState;
  
  /// Stream of state changes for reactive consumers
  Stream<GpsHealthState> get stateStream => _stateController.stream;
  
  /// Last known GPS accuracy in meters
  double? get lastAccuracy => _lastAccuracy;
  
  /// Duration since last GPS update (null if never received)
  Duration? get silentDuration {
    if (_lastGpsUpdate == null) return null;
    return DateTime.now().difference(_lastGpsUpdate!);
  }
  
  /// Ingest a GPS update and evaluate health state.
  /// Call this on every GPS position received.
  void ingestGpsUpdate(Position position) {
    final now = DateTime.now();
    _lastGpsUpdate = now;
    _lastAccuracy = position.accuracy;
    
    // Evaluate current state
    final newState = _evaluateState(now, position.accuracy);
    
    if (newState != _currentState) {
      final oldState = _currentState;
      _currentState = newState;
      _stateController.add(newState);
      
      dev.log(
        'GpsHealthMonitor: State changed $oldState -> $newState '
        '(accuracy: ${position.accuracy.toStringAsFixed(1)}m)',
        name: 'GpsHealthMonitor',
      );
    }
    
    // Reset degraded timer if we're healthy
    if (newState == GpsHealthState.healthy) {
      _degradedSince = null;
    }
  }
  
  /// Evaluate state periodically even without GPS updates.
  /// Call this from a timer to detect GPS dropout.
  void tick() {
    if (_lastGpsUpdate == null) return;
    
    final now = DateTime.now();
    final newState = _evaluateState(now, _lastAccuracy ?? 0.0);
    
    if (newState != _currentState) {
      final oldState = _currentState;
      _currentState = newState;
      _stateController.add(newState);
      
      dev.log(
        'GpsHealthMonitor: State changed $oldState -> $newState '
        '(silent for ${silentDuration?.inSeconds}s)',
        name: 'GpsHealthMonitor',
      );
    }
  }
  
  GpsHealthState _evaluateState(DateTime now, double accuracy) {
    final silent = _lastGpsUpdate != null 
        ? now.difference(_lastGpsUpdate!) 
        : Duration.zero;
    
    // Unavailable: GPS silent beyond threshold
    if (silent >= unavailableThreshold) {
      return GpsHealthState.unavailable;
    }
    
    // Check degraded conditions
    final isDegraded = silent >= degradedThreshold || accuracy > poorAccuracyMeters;
    
    if (isDegraded) {
      // Track when degradation started
      _degradedSince ??= now;
      
      // Require sustained degradation to transition
      if (now.difference(_degradedSince!) >= sustainedDegradationRequired) {
        return GpsHealthState.degraded;
      }
      
      // Not sustained long enough yet, stay at current state
      return _currentState == GpsHealthState.unavailable 
          ? GpsHealthState.unavailable 
          : GpsHealthState.healthy;
    }
    
    // Healthy: GPS arriving with good accuracy
    _degradedSince = null;
    return GpsHealthState.healthy;
  }
  
  /// Reset state (e.g., when tracking stops)
  void reset() {
    _currentState = GpsHealthState.healthy;
    _lastGpsUpdate = null;
    _degradedSince = null;
    _lastAccuracy = null;
  }
  
  void dispose() {
    _stateController.close();
  }
}
