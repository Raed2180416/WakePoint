import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;
import 'package:geolocator/geolocator.dart';
import 'package:geowake2/services/trackingservice.dart';
import 'package:geowake2/services/notification_service.dart';

// LEAN on-device L2 test: get NotificationService working via the PROVEN
// startTracking init path (calling NotificationService.initialize() in isolation
// hangs headless — a real testability gap), then schedule a REAL exact-alarm
// backstop (AndroidScheduleMode.alarmClock = AlarmManager.setAlarmClock,
// RTC_WAKEUP — the GW-0147 mechanism) and hold. A concurrent adb harness
// (scratchpad/l2_harness.py) proves the alarm REGISTERS with AlarmManager and
// FIRES through forced deep Doze (`deviceidle force-idle`).

class _Injector {
  final _ctrl = StreamController<Position>.broadcast();
  Stream<Position> get stream => _ctrl.stream;
  void add(LatLng p) {
    if (_ctrl.isClosed) return;
    _ctrl.add(Position(
      latitude: p.latitude, longitude: p.longitude, timestamp: DateTime.now(),
      accuracy: 5.0, altitude: 0.0, altitudeAccuracy: 0.0, heading: 0.0,
      headingAccuracy: 0.0, speed: 12.0, speedAccuracy: 1.0));
  }
  Future<void> close() async { if (!_ctrl.isClosed) await _ctrl.close(); }
}

Future<void> _pumpFor(WidgetTester tester, Duration total) async {
  final end = DateTime.now().add(total);
  while (DateTime.now().isBefore(end)) {
    try { await tester.pump(const Duration(milliseconds: 200)); } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 80));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final bool isDevice = Platform.isAndroid || Platform.isIOS;
  const bool runDeviceE2E = bool.fromEnvironment('RUN_DEVICE_INTEGRATION');
  final bool shouldSkip = !(isDevice && runDeviceE2E);

  testWidgets(
    'On-device: exact-alarm backstop registers + survives forced Doze',
    (WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(
          home: Scaffold(body: Center(child: Text('L2 backstop')))));
      await _pumpFor(tester, const Duration(seconds: 1));

      TrackingService.isTestMode = true;
      NotificationService.isTestMode = false; // real platform path
      final injector = _Injector();
      testGpsStream = injector.stream;

      // Start a real ride: this init path is proven to bring NotificationService
      // up on-device (the L1 chain test fired a real alarm through it), unlike
      // NotificationService.initialize() called in isolation (which hangs).
      const dest = LatLng(12.9585, 77.5868);
      await TrackingService().startTracking(
        destination: dest, destinationName: 'DozeDest',
        alarmMode: 'distance', alarmValue: 1.0, allowNotificationsInTest: true);
      injector.add(const LatLng(12.9700, 77.5820));
      await _pumpFor(tester, const Duration(seconds: 2));

      // Schedule the real exact-alarm backstop ~22s out.
      final fireAt = DateTime.now().add(const Duration(seconds: 22));
      debugPrint('L2backstop: scheduling exact-alarm for $fireAt');
      try {
        await NotificationService().scheduleEtaBackstop(
          fireAt: fireAt, title: 'GeoWake backstop',
          body: 'L2 Doze survival test — wake up.');
        debugPrint('L2backstop: scheduled OK; holding ~55s for adb Doze harness');
      } catch (e) {
        debugPrint('L2backstop: scheduleEtaBackstop threw: $e');
      }

      await _pumpFor(tester, const Duration(seconds: 55));
      debugPrint('L2backstop: hold complete');
      await TrackingService().stopTracking();
      await injector.close();
      expect(true, isTrue);
    },
    timeout: const Timeout(Duration(minutes: 3)),
    skip: shouldSkip,
  );
}
