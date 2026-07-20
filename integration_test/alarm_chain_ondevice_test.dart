import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;
import 'package:geolocator/geolocator.dart';
import 'package:geowake2/services/trackingservice.dart';
import 'package:geowake2/services/notification_service.dart';

// LEAN on-device alarm-chain test (emulator-tagged).
//
// The full-app integration test (device_alarm_integration_test.dart) is not
// viable on the headless CI emulator: app.main() initializes Google Mobile Ads +
// the Maps platform view, which crash under an out-of-date Play-services emulator
// (observed: zzgah IllegalAccessException in gms.internal.ads; RenderAndroidView
// on the black map). This test exercises the SHIPPED alarm pipeline
// (TrackingService -> EKF -> AlarmController -> NotificationService) directly,
// under a trivial widget, with NO map/ads — so the real on-device geolocator
// normalization + EKF + alarm-decision path runs and we can assert a real wake
// alarm is produced. Enable with --dart-define=RUN_DEVICE_INTEGRATION=true.

class _Injector {
  final _ctrl = StreamController<Position>.broadcast();
  Stream<Position> get stream => _ctrl.stream;
  bool get isClosed => _ctrl.isClosed;
  void add(LatLng p) {
    if (_ctrl.isClosed) return;
    _ctrl.add(Position(
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
    ));
  }

  Future<void> close() async {
    if (!_ctrl.isClosed) await _ctrl.close();
  }
}

Future<void> _pumpFor(WidgetTester tester, Duration total) async {
  final end = DateTime.now().add(total);
  while (DateTime.now().isBefore(end)) {
    try {
      await tester.pump(const Duration(milliseconds: 100));
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 40));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final bool isDevice = Platform.isAndroid || Platform.isIOS;
  const bool runDeviceE2E = bool.fromEnvironment('RUN_DEVICE_INTEGRATION');
  final bool shouldSkip = !(isDevice && runDeviceE2E);

  testWidgets(
    'On-device: shipped alarm chain fires on an approaching route (no UI/map/ads)',
    (WidgetTester tester) async {
      // Trivial host widget — keeps the binding + platform channels alive
      // without app.main()'s map/ads init.
      await tester.pumpWidget(const MaterialApp(
          home: Scaffold(body: Center(child: Text('L1 harness')))));
      await _pumpFor(tester, const Duration(seconds: 1));

      TrackingService.isTestMode = true;
      NotificationService.isTestMode = false; // let the real platform path run
      NotificationService.clearTestRecordedAlarms();
      NotificationService.testOnShowWakeUpAlarm =
          (String t, String b, bool a) async {
        debugPrint('L1chain: WAKE ALARM fired -> "$t" / "$b" (autoDismiss=$a)');
      };

      final injector = _Injector();
      testGpsStream = injector.stream;

      final destination = const LatLng(12.9585, 77.5868);
      String? startError;
      try {
        await TrackingService().startTracking(
          destination: destination,
          destinationName: 'DeviceDest',
          alarmMode: 'distance',
          alarmValue: 1.0,
          allowNotificationsInTest: true,
        );
      } catch (e, st) {
        startError = '$e';
        debugPrint('L1chain: startTracking threw: $e\n$st');
      }
      expect(startError, isNull,
          reason: 'startTracking must not throw on-device (chain wiring)');
      await _pumpFor(tester, const Duration(seconds: 1));

      // Approach the destination; the last point is the destination itself,
      // well within the 1 km distance threshold.
      final route = <LatLng>[
        const LatLng(12.9700, 77.5820),
        const LatLng(12.9660, 77.5840),
        const LatLng(12.9620, 77.5855),
        const LatLng(12.9600, 77.5862),
        destination,
      ];
      for (final p in route) {
        injector.add(p);
        await _pumpFor(tester, const Duration(milliseconds: 700));
      }
      // Hold at the destination so the fire condition is evaluated repeatedly.
      final deadline = DateTime.now().add(const Duration(seconds: 45));
      while (NotificationService.testRecordedAlarms.isEmpty &&
          DateTime.now().isBefore(deadline)) {
        injector.add(destination);
        await _pumpFor(tester, const Duration(milliseconds: 700));
      }

      debugPrint(
          'L1chain: recorded alarms = ${NotificationService.testRecordedAlarms.length}');
      expect(NotificationService.testRecordedAlarms.isNotEmpty, true,
          reason: 'the shipped TrackingService->EKF->AlarmController->'
              'NotificationService chain must produce a wake alarm on-device '
              'when the injected route reaches the destination');

      await TrackingService().stopTracking();
      await injector.close();
      await _pumpFor(tester, const Duration(seconds: 1));
    },
    timeout: const Timeout(Duration(minutes: 3)),
    skip: shouldSkip,
  );
}
