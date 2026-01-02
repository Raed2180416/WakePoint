import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/alarm_evaluator.dart';
import 'package:geowake2/services/transfer_utils.dart';
import 'dart:developer' as dev;
import 'package:google_maps_flutter/google_maps_flutter.dart';

// Minimal mock for dependencies if needed (none really needed for static method)

void main() {
  test('AlarmEvaluator Stability: Reject Duplicate Leg ID under Drift', () {
    // 1. Setup Initial Leg (Metro)
    // Topological Identity: "Purple Line" + "Station A" -> "Station B"
    final legA = TransitLegStops(
      legStartMeters: 0,
      legEndMeters: 1000,
      numStops: 3,
      lineName: 'Purple Line',
      stopMeters: [0, 500, 1000],
      stopNames: ['Station A', 'Station B', 'Station C'], // Topology
      stopPositions: [
        const LatLng(0, 0),
        const LatLng(0, 0),
        const LatLng(0, 0),
      ],
      isMetro: true,
      isActualPositions: false,
    );
    dev.log('Leg A ID: ${legA.legId}', name: 'LegStabilityTest');

    // 2. Evaluate Initial Alarm (Should Fire)
    // Progress: 600m (Passed Stop 1/500m). Total=3. Passed=1.
    // N=2. Target=(3-2)=1. Passed>=Target -> True.
    final resultA = AlarmEvaluator.evaluateCoinciding(
      mode: AlarmMode.stops,
      userValue: 2.0,
      progressMeters: 600.0,
      allEvents: [],
      firedEventIndexes: {},
      firedLegIds: {}, // EMPTY SET - First time
      isMetroLeg: true,
      transitLegs: [legA],
      currentLegIndex: 0,
      isFinalLeg: false,
    );

    expect(
      resultA,
      isNotNull,
      reason: 'Should fire for initial leg (Passed Stop B)',
    );
    expect(resultA!.legId, equals(legA.legId));

    dev.log('Initial Alarm Fired Validated.', name: 'LegStabilityTest');

    // 3. Setup Drifted Leg
    // Meters shifted by 10m, but Stop Names IDENTICAL.
    final legADrifted = TransitLegStops(
      legStartMeters: 10, // DRIFT
      legEndMeters: 1010, // DRIFT
      numStops: 3,
      lineName: 'Purple Line',
      stopMeters: [10, 510, 1010],
      stopNames: ['Station A', 'Station B', 'Station C'], // MATCHES
      stopPositions: [
        const LatLng(0, 0),
        const LatLng(0, 0),
        const LatLng(0, 0),
      ],
      isMetro: true,
      isActualPositions: false,
    );
    dev.log(
      'Leg A (Drifted) ID: ${legADrifted.legId}',
      name: 'LegStabilityTest',
    );

    // 4. Verify ID Stability
    expect(
      legADrifted.legId,
      equals(legA.legId),
      reason: 'Leg ID must be robust to meter drift',
    );

    // 5. Evaluate Drifted Alarm
    // CRITICAL: We pass the OLD ID in the fired set.
    final firedSet = {legA.legId};

    final resultB = AlarmEvaluator.evaluateCoinciding(
      mode: AlarmMode.stops,
      userValue: 2.0,
      progressMeters: 610.0, // Progress drifted too
      allEvents: [],
      firedEventIndexes: {},
      firedLegIds: firedSet, // CONTAINS ID
      isMetroLeg: true,
      transitLegs: [legADrifted],
      currentLegIndex: 0,
      isFinalLeg: false,
    );

    // 6. Assert Suppression
    if (resultB != null) {
      dev.log(
        'FAILURE: Alarm fired again! Reason: ${resultB.reason}',
        name: 'LegStabilityTest',
      );
    }
    expect(
      resultB,
      isNull,
      reason: 'Should suppress alarm because Leg ID is in fired set',
    );

    dev.log(
      'SUCCESS: Duplicate alarm suppressed by logical ID.',
      name: 'LegStabilityTest',
    );
  });

  test('LegId Stability: Walk-to leg ignores station name', () {
    final legWalkA = TransitLegStops(
      legStartMeters: 0,
      legEndMeters: 800,
      numStops: 0,
      lineName: 'Walk to Station A',
      stopMeters: const [],
      stopNames: const [],
      stopPositions: const [],
      isMetro: false,
      isActualPositions: false,
    );

    final legWalkB = TransitLegStops(
      legStartMeters: 0,
      legEndMeters: 800,
      numStops: 0,
      lineName: 'Walk to Station B',
      stopMeters: const [],
      stopNames: const [],
      stopPositions: const [],
      isMetro: false,
      isActualPositions: false,
    );

    expect(
      legWalkB.legId,
      equals(legWalkA.legId),
      reason:
          'Walk-to legId must not depend on dynamic station name; otherwise preBoarding can refire.',
    );
  });
}
