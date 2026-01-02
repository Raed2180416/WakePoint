// lib/services/tracking/heartbeat_monitor.dart
//
// Detects when the foreground Flutter process has been swiped away/killed by
// monitoring a periodic heartbeat sent from the foreground isolate.

import 'dart:async';
import 'dart:developer' as dev;

import 'package:geowake2/core/logging/app_logger.dart';
import 'package:geowake2/services/notification_service.dart';
import 'package:geowake2/services/tracking_state_store.dart';

class HeartbeatMonitor {
  final bool Function() isEnabled;
  final Duration timeout;
  final Duration checkInterval;

  DateTime? _lastHeartbeat;
  Timer? _timer;

  HeartbeatMonitor({
    required this.isEnabled,
    this.timeout = const Duration(seconds: 4),
    this.checkInterval = const Duration(seconds: 2),
  });

  bool get isRunning => _timer != null;

  void recordHeartbeat() {
    _lastHeartbeat = DateTime.now();
  }

  void ensureStarted() {
    if (!isRunning) {
      start();
    }
  }

  void start() {
    if (!isEnabled()) return;

    _lastHeartbeat ??= DateTime.now();
    _timer?.cancel();
    _timer = Timer.periodic(checkInterval, (_) async {
      final last = _lastHeartbeat;
      if (last == null) return;

      final elapsed = DateTime.now().difference(last);
      if (elapsed <= timeout) return;

      dev.log(
        'DEBUG: Heartbeat timeout - foreground gone for ${elapsed.inSeconds}s',
        name: 'HeartbeatMonitor',
      );

      try {
        final active = await TrackingStateStore.isActive();
        final alreadyPaused = await TrackingStateStore.isPaused();

        if (!active || alreadyPaused) {
          dev.log(
            'DEBUG: Not showing pause - active=$active, paused=$alreadyPaused',
            name: 'HeartbeatMonitor',
          );
          return;
        }

        dev.log(
          'DEBUG: Showing tracking paused notification (heartbeat timeout)',
          name: 'HeartbeatMonitor',
        );

        await TrackingStateStore.setPaused(true);
        final snapshot = await TrackingStateStore.loadSnapshot();
        await NotificationService().cancelJourneyProgress();
        await NotificationService().showTrackingPaused(
          destinationName: snapshot?.destinationName,
        );

        // Stop monitoring while paused.
        stop();
      } catch (e) {
        trackingLog.debug(
          'Heartbeat timeout handling failed',
          data: {'error': e.toString()},
        );
      }
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _lastHeartbeat = null;
  }
}
