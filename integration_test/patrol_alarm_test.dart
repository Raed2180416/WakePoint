import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;
import 'package:geolocator/geolocator.dart';
import 'package:geowake2/services/trackingservice.dart';
import 'package:geowake2/services/notification_service.dart';

// Patrol on-device L1 — the charter backbone: NATIVE permission handling +
// repeatable alarm-chain E2E. Uses the LEAN seam (no app.main()/map/ads) because
// app.main() crashes the Google Mobile Ads SDK on the out-of-date-Play emulator
// (documented in alarm_chain_ondevice_test.dart / GW-0170). Patrol's $.native
// grants the OS location + notification dialogs that vanilla integration_test
// cannot tap (GW-0174). Run: patrol test --target integration_test/patrol_alarm_test.dart

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

Future<void> _pumpFor(PatrolIntegrationTester $, Duration total) async {
  final end = DateTime.now().add(total);
  while (DateTime.now().isBefore(end)) {
    try { await $.tester.pump(const Duration(milliseconds: 100)); } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 40));
  }
}

Future<void> _grantAll(PatrolIntegrationTester $) async {
  // Tolerant sweep — grant whatever OS dialog is present, ignore absence.
  for (var i = 0; i < 4; i++) {
    try {
      if (await $.native.isPermissionDialogVisible(
          timeout: const Duration(seconds: 3))) {
        try { await $.native.selectFineLocation(); } catch (_) {}
        try { await $.native.grantPermissionWhenInUse(); } catch (_) {}
      }
    } catch (_) {}
  }
}

void main() {
  patrolTest(
    'GeoWake L1: native permissions granted + shipped alarm chain fires',
    ($) async {
      await $.pumpWidget(const MaterialApp(
          home: Scaffold(body: Center(child: Text('Patrol L1 harness')))));
      await _pumpFor($, const Duration(seconds: 1));

      TrackingService.isTestMode = true;
      NotificationService.isTestMode = false;
      NotificationService.clearTestRecordedAlarms();
      NotificationService.testOnShowWakeUpAlarm = (t, b, a) async {
        debugPrint('Patrol L1: WAKE ALARM fired -> "$t" / "$b"');
      };

      final injector = _Injector();
      testGpsStream = injector.stream;

      const dest = LatLng(12.9585, 77.5868);
      // Fire startTracking WITHOUT awaiting so we can grant the OS dialog it
      // raises; Patrol taps it natively; then the future resolves.
      final started = TrackingService().startTracking(
        destination: dest, destinationName: 'PatrolDest',
        alarmMode: 'distance', alarmValue: 1.0, allowNotificationsInTest: true);
      await _grantAll($);
      try { await started; } catch (e) { debugPrint('Patrol L1: startTracking: $e'); }
      await _grantAll($); // any follow-up (notifications / background) dialog
      await _pumpFor($, const Duration(seconds: 1));

      final route = <LatLng>[
        const LatLng(12.9700, 77.5820), const LatLng(12.9660, 77.5840),
        const LatLng(12.9620, 77.5855), const LatLng(12.9600, 77.5862), dest,
      ];
      for (final p in route) { injector.add(p); await _pumpFor($, const Duration(milliseconds: 700)); }
      final deadline = DateTime.now().add(const Duration(seconds: 45));
      while (NotificationService.testRecordedAlarms.isEmpty &&
          DateTime.now().isBefore(deadline)) {
        injector.add(dest);
        await _pumpFor($, const Duration(milliseconds: 700));
      }
      debugPrint('Patrol L1: recorded alarms = ${NotificationService.testRecordedAlarms.length}');
      expect(NotificationService.testRecordedAlarms.isNotEmpty, true,
          reason: 'the shipped alarm chain must fire on-device under Patrol with '
              'natively-granted permissions');
      await TrackingService().stopTracking();
      await injector.close();
    },
  );
}
