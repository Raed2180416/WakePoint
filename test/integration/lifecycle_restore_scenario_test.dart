import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:geowake2/services/tracking_state_store.dart';

/// End-to-end lifecycle scenario for the core reliability promise:
///
///   arm -> OS kills the app -> cold restore -> re-arm + backstop.
///
/// The wake alarm's whole value proposition is that a metro rider can lock
/// their phone / let the OS reap the process, and tracking (plus the alarm
/// backstop) still resumes from persisted state. That persisted state is the
/// [TrackingSnapshot] stored in SharedPreferences by [TrackingStateStore].
///
/// These tests drive the *real* store code paths headlessly:
///   * SharedPreferences via `setMockInitialValues({})` (the mock's in-memory
///     map plays the role of the on-disk prefs file that survives a kill).
///   * A process death is modelled by dropping the store's cached prefs handle
///     (`resetCacheForTests`) and re-reading through a fresh `loadSnapshot()` —
///     RAM caches are gone, the persisted file survives, exactly like a real
///     OS reap.
///
/// The cardinal sins we attack here: losing the trip after a kill (=> alarm
/// NEVER fires) and resurrecting a finished trip. So every field must survive
/// the round-trip, corrupt/partial state must fail safe as "no active trip",
/// and a background position-only refresh must not silently wipe the route
/// directions that the transit backstop depends on.

const String _snapshotKey = 'tracking_snapshot_v1';

/// A realistic metro journey snapshot: Churchgate -> Andheri on Mumbai's
/// Western Line, "wake me 2 stops before" (stops mode), with a full transit
/// directions payload and live EKF along-track state attached.
///
/// The directions map is built to contain *only* the fields that the store's
/// snapshot minimizer preserves, so the transit content round-trips intact.
TrackingSnapshot _metroSnapshot({
  double userLat = 18.9450,
  double userLng = 72.8300,
}) {
  return TrackingSnapshot(
    destinationName: 'Andheri Station',
    destinationLat: 19.1197,
    destinationLng: 72.8464,
    alarmMode: 'stops',
    alarmValue: 2.0,
    metroMode: true,
    userLat: userLat,
    userLng: userLng,
    createdAt: DateTime(2026, 7, 15, 9, 41, 12),
    ekfS: 4210.5,
    ekfSigmaS: 37.25,
    ekfMode: 'transit',
    directions: {
      'status': 'OK',
      'routes': [
        {
          'overview_polyline': {'points': 'ymnrCkxvxMabcdEF'},
          'simplified_polyline': 'ymnrCkxvxM',
          'legs': [
            {
              'duration': {'value': 1980},
              'distance': {'value': 23400},
              'steps': [
                {
                  'travel_mode': 'TRANSIT',
                  'distance': {'value': 23400},
                  'duration': {'value': 1980},
                  'polyline': {'points': 'ymnrCkxvxMstep'},
                  'start_location': {'lat': 18.9322, 'lng': 72.8264},
                  'end_location': {'lat': 19.1197, 'lng': 72.8464},
                  'transit_details': {
                    'num_stops': 8,
                    'departure_stop': {
                      'name': 'Churchgate',
                      'location': {'lat': 18.9322, 'lng': 72.8264},
                    },
                    'arrival_stop': {
                      'name': 'Andheri',
                      'location': {'lat': 19.1197, 'lng': 72.8464},
                    },
                    'line': {
                      'short_name': 'WR',
                      'name': 'Western Line',
                      'id': 'line_wr_local',
                      'vehicle': {'type': 'HEAVY_RAIL'},
                    },
                  },
                },
              ],
            },
          ],
        },
      ],
    },
  );
}

void main() {
  // SharedPreferences plugin binding is touched via setMockInitialValues.
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // Store caches its prefs handle statically; reset so each scenario starts
    // from a clean "just installed / just booted" state.
    TrackingStateStore.resetCacheForTests();
  });

  group('lifecycle: process-death -> restore -> backstop', () {
    test('fresh install / no prior trip => loadSnapshot is null (nothing to resume)',
        () async {
      expect(await TrackingStateStore.loadSnapshot(), isNull);
      expect(await TrackingStateStore.isActive(), isFalse);
    });

    test(
        'full metro journey survives an OS kill: every field round-trips and re-arms tracking',
        () async {
      final armed = _metroSnapshot();

      // (1) Arm: tracking is active and the snapshot is persisted.
      await TrackingStateStore.setActive(true);
      await TrackingStateStore.saveSnapshot(armed);

      // (2) "OS kills the app": all in-memory state is gone. We model this by
      // dropping the store's cached prefs handle — the persisted prefs file
      // survives the reap, the RAM cache does not.
      TrackingStateStore.resetCacheForTests();

      // (3) Cold restore: re-read purely from persisted state. This is exactly
      // what re-arms tracking and the alarm backstop after the kill.
      final restored = await TrackingStateStore.loadSnapshot();
      expect(restored, isNotNull,
          reason: 'persisted trip must survive a process kill');

      // Active flag must also survive so the app knows to resume, not idle.
      expect(await TrackingStateStore.isActive(), isTrue);

      // --- Every scalar field survives ---
      expect(restored!.destinationName, 'Andheri Station');
      expect(restored.destinationLat, closeTo(19.1197, 1e-9));
      expect(restored.destinationLng, closeTo(72.8464, 1e-9));
      expect(restored.alarmMode, 'stops');
      expect(restored.alarmValue, closeTo(2.0, 1e-9));
      expect(restored.metroMode, isTrue);
      expect(restored.userLat, closeTo(18.9450, 1e-9));
      expect(restored.userLng, closeTo(72.8300, 1e-9));
      expect(restored.createdAt.isAtSameMomentAs(armed.createdAt), isTrue,
          reason: 'trip start time must round-trip exactly');

      // --- EKF along-track state survives (feeds warm-start of the estimator
      // so the backstop keeps a good distance estimate after restore) ---
      expect(restored.ekfS, closeTo(4210.5, 1e-9));
      expect(restored.ekfSigmaS, closeTo(37.25, 1e-9));
      expect(restored.ekfMode, 'transit');

      // --- Transit directions (the backstop's route knowledge) survive ---
      expect(restored.directions, isNotNull,
          reason: 'route directions must survive; the transit backstop needs '
              'the line + stops to know when to fire');
      final dir = restored.directions!;
      expect(dir['status'], 'OK');

      final routes = dir['routes'] as List;
      expect(routes, hasLength(1));
      final route = routes.first as Map;
      expect((route['overview_polyline'] as Map)['points'], 'ymnrCkxvxMabcdEF');
      expect(route['simplified_polyline'], 'ymnrCkxvxM');

      final legs = route['legs'] as List;
      expect(legs, hasLength(1));
      final leg = legs.first as Map;
      expect((leg['duration'] as Map)['value'], 1980);
      expect((leg['distance'] as Map)['value'], 23400);

      final steps = leg['steps'] as List;
      expect(steps, hasLength(1));
      final step = steps.first as Map;
      expect(step['travel_mode'], 'TRANSIT');
      expect((step['polyline'] as Map)['points'], 'ymnrCkxvxMstep');
      expect((step['start_location'] as Map)['lat'], closeTo(18.9322, 1e-9));
      expect((step['end_location'] as Map)['lng'], closeTo(72.8464, 1e-9));

      final td = step['transit_details'] as Map;
      expect(td['num_stops'], 8);
      expect((td['departure_stop'] as Map)['name'], 'Churchgate');
      expect((td['arrival_stop'] as Map)['name'], 'Andheri');
      final line = td['line'] as Map;
      expect(line['short_name'], 'WR');
      expect(line['name'], 'Western Line');
      expect(line['id'], 'line_wr_local');
      expect((line['vehicle'] as Map)['type'], 'HEAVY_RAIL');
    });

    test(
        'background position-only refresh must NOT wipe the directions backstop',
        () async {
      // Arm with full route knowledge.
      await TrackingStateStore.saveSnapshot(_metroSnapshot());

      // Background components refresh the snapshot frequently with a fresh GPS
      // fix but WITHOUT re-attaching the (heavy) directions payload. The store
      // is responsible for preserving the previously-persisted directions so
      // the transit backstop is not silently disarmed mid-trip.
      const movedLat = 19.0176; // rider has progressed up the line
      const movedLng = 72.8562;
      final positionOnly = TrackingSnapshot(
        destinationName: 'Andheri Station',
        destinationLat: 19.1197,
        destinationLng: 72.8464,
        alarmMode: 'stops',
        alarmValue: 2.0,
        metroMode: true,
        userLat: movedLat,
        userLng: movedLng,
        createdAt: DateTime(2026, 7, 15, 9, 41, 12),
        directions: null, // <-- background update carries no directions
      );
      await TrackingStateStore.saveSnapshot(positionOnly);

      // Simulate the kill after the background update.
      TrackingStateStore.resetCacheForTests();
      final restored = await TrackingStateStore.loadSnapshot();

      expect(restored, isNotNull);
      // Updated position took effect...
      expect(restored!.userLat, closeTo(movedLat, 1e-9));
      expect(restored.userLng, closeTo(movedLng, 1e-9));
      // ...but the directions backstop is intact. Losing this would mean a
      // metro alarm that can NEVER fire after a kill.
      expect(restored.directions, isNotNull,
          reason: 'a directions-less background refresh must not erase the '
              'persisted route the backstop relies on');
      final steps = ((((restored.directions!['routes'] as List).first
                  as Map)['legs'] as List)
              .first as Map)['steps'] as List;
      final line =
          ((steps.first as Map)['transit_details'] as Map)['line'] as Map;
      expect(line['name'], 'Western Line');
    });

    test('finished trip: clearSnapshot() prevents resurrection after a kill',
        () async {
      await TrackingStateStore.setActive(true);
      await TrackingStateStore.saveSnapshot(_metroSnapshot());
      expect(await TrackingStateStore.loadSnapshot(), isNotNull);

      // Trip completes; the app tears down tracking.
      await TrackingStateStore.clearSnapshot();
      await TrackingStateStore.setActive(false);

      // A later process kill + cold boot must NOT resurrect the finished trip.
      TrackingStateStore.resetCacheForTests();
      expect(await TrackingStateStore.loadSnapshot(), isNull,
          reason: 'a cleared (finished) trip must not resume');
      expect(await TrackingStateStore.isActive(), isFalse);
    });

    test('corrupt persisted snapshot fails safe as "no active trip"', () async {
      // Directly seed a corrupt blob under the store's key, as a truncated
      // write during a kill might leave behind.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_snapshotKey, '{"destinationName":"Andheri",');

      // Must not throw (completes normally), must be treated as no resumable
      // trip (returns null).
      TrackingStateStore.resetCacheForTests();
      await expectLater(
          TrackingStateStore.loadSnapshot(), completion(isNull));
    });

    test(
        'partial snapshot missing load-bearing coordinates fails safe (no crash, no active trip)',
        () async {
      // Valid JSON, but a required coordinate (destinationLat) is absent — the
      // trip cannot be safely re-armed, so it must read back as "no trip"
      // rather than restoring a nonsensical destination.
      final partial = <String, dynamic>{
        'destinationName': 'Andheri Station',
        // 'destinationLat' intentionally omitted
        'destinationLng': 72.8464,
        'alarmMode': 'stops',
        'alarmValue': 2.0,
        'metroMode': true,
        'userLat': 18.9450,
        'userLng': 72.8300,
        'createdAt': DateTime(2026, 7, 15, 9, 41, 12).toIso8601String(),
      };
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_snapshotKey, jsonEncode(partial));

      TrackingStateStore.resetCacheForTests();
      expect(await TrackingStateStore.loadSnapshot(), isNull,
          reason: 'a snapshot missing a required coordinate must fail safe');
    });

    test('wrong-typed coordinate in persisted snapshot fails safe', () async {
      // A coordinate persisted as a non-numeric string must not throw or
      // restore a bogus trip.
      final broken = <String, dynamic>{
        'destinationName': 'Andheri Station',
        'destinationLat': 'not-a-number',
        'destinationLng': 72.8464,
        'alarmMode': 'stops',
        'alarmValue': 2.0,
        'metroMode': true,
        'userLat': 18.9450,
        'userLng': 72.8300,
        'createdAt': DateTime(2026, 7, 15, 9, 41, 12).toIso8601String(),
      };
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_snapshotKey, jsonEncode(broken));

      TrackingStateStore.resetCacheForTests();
      expect(await TrackingStateStore.loadSnapshot(), isNull);
    });

    test('empty persisted snapshot string fails safe', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_snapshotKey, '');

      TrackingStateStore.resetCacheForTests();
      expect(await TrackingStateStore.loadSnapshot(), isNull);
    });
  });
}
