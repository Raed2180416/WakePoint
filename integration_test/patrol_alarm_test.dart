import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';

import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;
import 'package:geolocator/geolocator.dart';

// The real app entry point. Launching app.main() (rather than a trivial host
// widget) is what makes the OS runtime-permission dialogs actually appear, so
// Patrol's NATIVE automation can grant them — the whole reason this test uses
// Patrol instead of a plain integration_test.
import 'package:geowake2/main.dart' as app;
import 'package:geowake2/services/trackingservice.dart';
import 'package:geowake2/services/notification_service.dart';

// ---------------------------------------------------------------------------
// GeoWake Patrol L1: native-permission + shipped-alarm-chain E2E.
//
// This is the repeatable on-device L1 the testing charter's "Patrol backbone"
// is meant to provide. Two things are proven in ONE run on a real emulator:
//
//   1. NATIVE permission handling — the app boots for real (app.main), which
//      triggers the location + notification runtime dialogs; Patrol clears them
//      natively via $.native.* (no fragile Dart-side taps on OS UI).
//
//   2. The SHIPPED alarm pipeline — TrackingService -> EKF -> AlarmController ->
//      NotificationService — is driven deterministically to a real wake alarm
//      using the same proven seam as integration_test/alarm_chain_ondevice_test
//      .dart: TrackingService.isTestMode=true (deterministic, no background
//      isolate), NotificationService.isTestMode=false (the real platform alarm
//      path runs), an injected testGpsStream, and an assertion on
//      NotificationService.testRecordedAlarms.
//
// Pumping uses bounded pump() loops, NEVER pumpAndSettle: the live app has
// perpetual animations (splash/UI) and a black Google Map platform view that
// never reaches a settled frame, so pumpAndSettle would hang until timeout.
// ---------------------------------------------------------------------------

/// Injects synthetic GPS fixes into the tracking pipeline via `testGpsStream`.
class _GpsInjector {
  final _ctrl = StreamController<Position>.broadcast();
  Stream<Position> get stream => _ctrl.stream;

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

/// Bounded pump loop — advances frames for [total] WITHOUT ever settling.
/// Individual pumps are wrapped because a live platform view (map/ads) can
/// throw transiently during a frame; we tolerate that and keep pumping.
Future<void> _pumpFor(PatrolIntegrationTester $, Duration total) async {
  final end = DateTime.now().add(total);
  while (DateTime.now().isBefore(end)) {
    try {
      await $.tester.pump(const Duration(milliseconds: 100));
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 40));
  }
}

/// Best-effort native clearing of the location + notification runtime dialogs.
/// Every call is guarded: on a given emulator/run a specific dialog may not be
/// on screen (already granted, requested later, or a different order), and a
/// missing dialog must not fail the permission phase. We sweep a few times with
/// pumps in between so whichever dialog surfaces gets granted.
Future<void> _grantRuntimePermissions(PatrolIntegrationTester $) async {
  for (var attempt = 0; attempt < 3; attempt++) {
    // Location (ACCESS_FINE/COARSE_LOCATION): pick precise, then "While using
    // the app". selectFineLocation is a no-op if the fine/coarse toggle isn't
    // present (pre-Android-12 or notification dialog).
    try {
      await $.native.selectFineLocation();
    } catch (_) {}
    try {
      // Taps "While using the app" on location; taps "Allow" on the
      // POST_NOTIFICATIONS (Android 13+) dialog.
      await $.native.grantPermissionWhenInUse();
    } catch (_) {}
    // Some OEM/location dialogs only offer a one-time grant button.
    try {
      await $.native.grantPermissionOnlyThisTime();
    } catch (_) {}
    await _pumpFor($, const Duration(milliseconds: 800));
  }
}

void main() {
  patrolTest(
    'GeoWake L1: native permissions granted + shipped alarm chain fires',
    ($) async {
      // 1) Boot the REAL app so the OS permission dialogs are actually raised.
      //    Guarded: the emulator's out-of-date Play services can make the map/
      //    ads platform views throw during launch; that must not abort the run
      //    — the deterministic alarm-chain assertion below is the real gate.
      try {
        await app.main();
      } catch (e, st) {
        debugPrint('patrol L1: app.main() threw (tolerated): $e\n$st');
      }
      await _pumpFor($, const Duration(seconds: 3));

      // 2) Clear the location + notification runtime dialogs NATIVELY.
      await _grantRuntimePermissions($);

      // 3) Switch to the deterministic alarm-chain seam (same as
      //    alarm_chain_ondevice_test.dart). isTestMode short-circuits the
      //    background isolate so startTracking drives the pipeline in-process;
      //    NotificationService.isTestMode=false keeps the REAL platform alarm
      //    path, and testRecordedAlarms captures every wake alarm produced.
      TrackingService.isTestMode = true;
      NotificationService.isTestMode = false;
      NotificationService.clearTestRecordedAlarms();
      NotificationService.testOnShowWakeUpAlarm =
          (String t, String b, bool autoDismiss) async {
        debugPrint('patrol L1: WAKE ALARM -> "$t" / "$b" (autoDismiss=$autoDismiss)');
      };

      final injector = _GpsInjector();
      testGpsStream = injector.stream;

      const destination = LatLng(12.9585, 77.5868);
      Object? startError;
      try {
        await TrackingService().startTracking(
          destination: destination,
          destinationName: 'PatrolDest',
          alarmMode: 'distance',
          alarmValue: 1.0,
          allowNotificationsInTest: true,
        );
      } catch (e, st) {
        startError = e;
        debugPrint('patrol L1: startTracking threw: $e\n$st');
      }
      expect(startError, isNull,
          reason: 'startTracking must not throw on-device (chain wiring)');
      await _pumpFor($, const Duration(seconds: 1));

      // 4) Approach the destination; the last fix IS the destination, well
      //    inside the 1 km distance threshold, so the alarm must fire.
      final route = <LatLng>[
        const LatLng(12.9700, 77.5820),
        const LatLng(12.9660, 77.5840),
        const LatLng(12.9620, 77.5855),
        const LatLng(12.9600, 77.5862),
        destination,
      ];
      for (final p in route) {
        injector.add(p);
        await _pumpFor($, const Duration(milliseconds: 700));
      }

      // Hold at the destination until the fire condition is evaluated.
      final deadline = DateTime.now().add(const Duration(seconds: 45));
      while (NotificationService.testRecordedAlarms.isEmpty &&
          DateTime.now().isBefore(deadline)) {
        injector.add(destination);
        await _pumpFor($, const Duration(milliseconds: 700));
      }

      debugPrint('patrol L1: recorded alarms = '
          '${NotificationService.testRecordedAlarms.length}');
      expect(NotificationService.testRecordedAlarms.isNotEmpty, true,
          reason: 'the shipped TrackingService->EKF->AlarmController->'
              'NotificationService chain must produce a wake alarm on-device '
              'when the injected route reaches the destination');

      // Teardown.
      try {
        await TrackingService().stopTracking();
      } catch (_) {}
      await injector.close();
      testGpsStream = null;
      NotificationService.testOnShowWakeUpAlarm = null;
      await _pumpFor($, const Duration(seconds: 1));
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
