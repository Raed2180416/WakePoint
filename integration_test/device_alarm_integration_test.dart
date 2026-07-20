import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geowake2/services/trackingservice.dart';
import 'package:geowake2/services/notification_service.dart';
import 'package:geowake2/main.dart' as app;
import 'package:geolocator/geolocator.dart';

// Device integration test: Use foreground test mode (TrackingService.isTestMode=true)
// but keep platform notifications enabled. Inject GPS via testGpsStream so that
// full-screen notifications, vibration, and AlarmActivity still execute on-device.
//
// IMPORTANT (fixed 2026-07-20): the original test called tester.pumpAndSettle()
// after app.main(). GeoWake has perpetual animations (splash, pulsing dots) and a
// Google Maps platform view (RenderAndroidView), so pumpAndSettle() NEVER quiesces
// and the test hangs until the 5-min timeout (confirmed on emulator-5554: the app
// launched, rendered, then the driver SIGQUIT-probed an unresponsive test and
// tracking never started). All settling is now done with bounded pump() loops that
// advance a frame and yield real time, so the background stream/timer pipeline
// (TrackingService -> EKF -> AlarmController) runs without waiting on animations.

class SimpleLocationInjector {
  final _ctrl = StreamController<Position>.broadcast();
  Stream<Position> get stream => _ctrl.stream;
  Future<void> playRoute(
    List<LatLng> route, {
    Duration step = const Duration(milliseconds: 350),
  }) async {
    for (final p in route) {
      if (_ctrl.isClosed) return;
      _ctrl.add(
        Position(
          latitude: p.latitude,
          longitude: p.longitude,
          timestamp: DateTime.now(),
          accuracy: 5.0,
          altitude: 0.0,
          altitudeAccuracy: 0.0,
          heading: 0.0,
          headingAccuracy: 0.0,
          speed: 12.0,
          speedAccuracy: 1.0,
        ),
      );
      await Future<void>.delayed(step);
    }
  }

  Future<void> close() async {
    if (!_ctrl.isClosed) await _ctrl.close();
  }
}

/// Advance frames for [total] WITHOUT waiting for animations to settle (which
/// never happens with the splash/pulsing/map platform view). Pumps one frame
/// then yields real time so on-device timers + the injected GPS stream process.
Future<void> _pumpFor(WidgetTester tester, Duration total,
    {Duration step = const Duration(milliseconds: 100)}) async {
  final end = DateTime.now().add(total);
  while (DateTime.now().isBefore(end)) {
    try {
      await tester.pump(step);
    } catch (_) {
      // A RenderAndroidView layout hiccup from the black map platform view must
      // not abort the run — the alarm pipeline does not depend on the map.
    }
    await Future<void>.delayed(const Duration(milliseconds: 40));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final bool isDevice = Platform.isAndroid || Platform.isIOS;
  const bool runDeviceE2E = bool.fromEnvironment('RUN_DEVICE_INTEGRATION');
  final bool shouldSkip = !(isDevice && runDeviceE2E);

  testWidgets(
    'Device: end-to-end alarm flow via injected positions',
    (WidgetTester tester) async {
      // Launch the real app. NO pumpAndSettle — bounded pump instead.
      app.main();
      await _pumpFor(tester, const Duration(seconds: 4));

      // Foreground test mode: run pipelines in UI isolate but allow real notifications
      TrackingService.isTestMode = true;
      NotificationService.isTestMode = false;
      NotificationService.clearTestRecordedAlarms();
      NotificationService.testOnShowWakeUpAlarm =
          (String t, String b, bool a) async {
        debugPrint('L1: wake-up alarm shown: "$t" / "$b"');
      };

      final injector = SimpleLocationInjector();
      testGpsStream = injector.stream;

      // Start tracking (distance mode, destination ~1 km away).
      final destination = const LatLng(12.9585, 77.5868);
      await TrackingService().startTracking(
        destination: destination,
        destinationName: 'DeviceDest',
        alarmMode: 'distance',
        alarmValue: 1.0,
        allowNotificationsInTest: true,
      );
      await _pumpFor(tester, const Duration(seconds: 1));

      // Feed a route that closes on the destination, pumping concurrently.
      final route = <LatLng>[
        const LatLng(12.9630, 77.5850),
        const LatLng(12.9615, 77.5858),
        const LatLng(12.9600, 77.5862),
        const LatLng(12.9590, 77.5865),
        destination,
      ];
      // Fire injection without awaiting; pump the framework in parallel.
      // ignore: unawaited_futures
      final play = injector.playRoute(route).then((_) async {
        for (int i = 0; i < 8 && !injector._ctrl.isClosed; i++) {
          await injector.playRoute([destination],
              step: const Duration(milliseconds: 400));
        }
      });

      // Poll up to 60 s for the alarm to be recorded, pumping throughout.
      final startWait = DateTime.now();
      while (NotificationService.testRecordedAlarms.isEmpty &&
          DateTime.now().difference(startWait) < const Duration(seconds: 60)) {
        await _pumpFor(tester, const Duration(milliseconds: 500));
      }
      await play.catchError((_) {});

      debugPrint('L1: recorded alarms = '
          '${NotificationService.testRecordedAlarms.length}');
      expect(NotificationService.testRecordedAlarms.isNotEmpty, true,
          reason: 'the shipped tracking->EKF->alarm chain must fire an alarm '
              'on-device when the injected route reaches the destination');

      await TrackingService().stopTracking();
      await injector.close();
      await _pumpFor(tester, const Duration(seconds: 1));
    },
    timeout: Timeout(Duration(minutes: 4)),
    skip: shouldSkip,
  );
}
