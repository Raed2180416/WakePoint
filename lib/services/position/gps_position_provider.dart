// lib/services/position/gps_position_provider.dart
//
// GPS-based position provider implementation.
// Wraps the geolocator package with the PositionProvider interface.

import 'dart:async';
import 'dart:io' show Platform;
import 'package:geolocator/geolocator.dart';
import 'package:geowake2/core/logging/app_logger.dart';
import 'package:geowake2/services/position/position_provider.dart';

/// Default location settings, platform-branched.
///
/// On iOS, background location delivery requires BOTH the `location` entry in
/// UIBackgroundModes (ios/Runner/Info.plist) AND `allowBackgroundLocationUpdates`
/// on an [AppleSettings] instance — the plist key alone is inert and the stream
/// silently stops delivering the moment the app is backgrounded. Because WakePoint's
/// whole purpose is to keep tracking through an underground GPS blackout while the
/// phone is locked, this is load-bearing, not cosmetic.
LocationSettings _defaultLocationSettings() {
  if (Platform.isIOS) {
    return AppleSettings(
      accuracy: LocationAccuracy.high,
      activityType: ActivityType.otherNavigation,
      distanceFilter: 5,
      pauseLocationUpdatesAutomatically: false,
      // Keep the standard-location-service running in the background.
      allowBackgroundLocationUpdates: true,
      // Show the blue status bar so the user knows tracking is active (App Store
      // review expects this when allowBackgroundLocationUpdates is set).
      showBackgroundLocationIndicator: true,
    );
  }
  return const LocationSettings(
    accuracy: LocationAccuracy.high,
    distanceFilter: 5, // meters
  );
}

/// GPS-based position provider using the device's location services.
///
/// This is the primary position source when GPS is available.
/// When GPS drops out, the tracking service should switch to EKF.
class GpsPositionProvider implements PositionProvider {
  StreamSubscription<Position>? _subscription;
  final StreamController<Position> _controller =
      StreamController<Position>.broadcast();
  Position? _lastPosition;
  bool _isActive = false;

  /// Location settings for GPS accuracy
  final LocationSettings _locationSettings;

  GpsPositionProvider({LocationSettings? locationSettings})
    : _locationSettings = locationSettings ?? _defaultLocationSettings();

  @override
  Stream<Position> get positionStream => _controller.stream;

  @override
  Position? get currentPosition => _lastPosition;

  @override
  double get uncertainty => _lastPosition?.accuracy ?? 999.0;

  @override
  bool get isEstimated => false; // GPS is always "real"

  @override
  bool get isActive => _isActive;

  @override
  Future<void> start() async {
    if (_isActive) return;

    gpsLog.info('Starting GPS position provider');

    try {
      _subscription = Geolocator.getPositionStream(
        locationSettings: _locationSettings,
      ).listen(
        (Position position) {
          _lastPosition = position;
          _controller.add(position);
          gpsLog.debug(
            'GPS fix',
            data: {
              'lat': position.latitude.toStringAsFixed(6),
              'lng': position.longitude.toStringAsFixed(6),
              'accuracy': position.accuracy.toStringAsFixed(1),
              'speed': position.speed.toStringAsFixed(2),
            },
          );
        },
        onError: (error) {
          gpsLog.error('GPS stream error', error: error);
        },
      );
      _isActive = true;
    } catch (e, stack) {
      gpsLog.error('Failed to start GPS provider', error: e, stack: stack);
      rethrow;
    }
  }

  @override
  Future<void> stop() async {
    if (!_isActive) return;

    gpsLog.info('Stopping GPS position provider');
    await _subscription?.cancel();
    _subscription = null;
    _isActive = false;
  }

  @override
  void reset(Position anchorPosition) {
    _lastPosition = anchorPosition;
    gpsLog.debug(
      'GPS provider reset to anchor',
      data: {
        'lat': anchorPosition.latitude.toStringAsFixed(6),
        'lng': anchorPosition.longitude.toStringAsFixed(6),
      },
    );
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _controller.close();
    gpsLog.debug('GPS provider disposed');
  }
}
