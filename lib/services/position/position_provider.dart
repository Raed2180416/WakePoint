// lib/services/position/position_provider.dart
//
// Abstract interface for position providers.
// This allows swapping between GPS, EKF, or other position sources
// while maintaining a consistent API for the tracking service.

import 'dart:async';
import 'package:geolocator/geolocator.dart';

/// Abstract interface for position providers.
///
/// Implementations include:
/// - [GpsPositionProvider] - Real GPS from device
/// - [EkfPositionProvider] - Extended Kalman Filter (future)
/// - [SimulatedPositionProvider] - For testing
///
/// The tracking service will use this interface to get positions,
/// allowing seamless switching between GPS and dead reckoning.
abstract class PositionProvider {
  /// Stream of position updates.
  ///
  /// Implementations should emit positions at their natural rate
  /// (e.g., 1Hz for GPS, higher for IMU-based estimation).
  Stream<Position> get positionStream;

  /// The most recent position, or null if none available.
  Position? get currentPosition;

  /// Estimated position uncertainty in meters.
  ///
  /// For GPS, this comes from the platform's accuracy value.
  /// For EKF, this is derived from the covariance matrix.
  double get uncertainty;

  /// Whether the current position is estimated (true) or a real GPS fix (false).
  ///
  /// UI can use this to show different indicators for estimated vs real positions.
  bool get isEstimated;

  /// Whether this provider is currently active and producing positions.
  bool get isActive;

  /// Start providing positions.
  ///
  /// For GPS, this starts the location stream.
  /// For EKF, this starts sensor fusion.
  Future<void> start();

  /// Stop providing positions.
  ///
  /// Releases resources and stops any active streams.
  Future<void> stop();

  /// Reset the provider state with a known good position.
  ///
  /// Used when switching from EKF back to GPS - the GPS position
  /// becomes the new anchor point.
  void reset(Position anchorPosition);

  /// Dispose of all resources.
  Future<void> dispose();
}

/// Provider type for logging and debugging.
enum PositionProviderType {
  /// Real GPS from device
  gps,

  /// Extended Kalman Filter (sensor fusion)
  ekf,

  /// Simulated positions for testing
  simulated,
}
