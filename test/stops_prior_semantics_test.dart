// Test to verify "N stops prior" alarm semantics.
//
// The user's mental model:
// - "1 stop before" = fire at the station just before the target
// - "2 stops before" = fire at the station two stops before the target
//
// Implementation:
// - toEventStops counts REMAINING intermediate stops (not including the target)
// - When at the last stop before target, toEventStops = 0
// - Fire when toEventStops < thresholdStops (strict inequality)
//
// Example: Transfer at station E, intermediate stops are B, C, D
// - At B: toEventStops = 2 (C, D are between user and E)
// - At C: toEventStops = 1 (D is between user and E)
// - At D: toEventStops = 0 (no stops between user and E)
//
// With threshold = 1:
// - Should fire at D (0 < 1 = true)
// - Should NOT fire at C (1 < 1 = false)
//
// With threshold = 2:
// - Should fire at D (0 < 2 = true) and at C (1 < 2 = true)
// - Should NOT fire at B (2 < 2 = false)

@TestOn('vm')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/transfer_utils.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

void main() {
  group('Stops Prior Semantics', () {
    test(
      'threshold=1 fires exactly 1 stop before target (at last intermediate stop)',
      () async {
        // Setup: 4 intermediate stops, transfer at 5000m
        // Stop positions: 1000m, 2000m, 3000m, 4000m (intermediate)
        // Transfer at 5000m

        final transitLegs = [
          TransitLegStops(
            legStartMeters: 0,
            legEndMeters: 5000,
            numStops: 4,
            stopPositions: [
              const LatLng(0.009, 0.0), // Stop 1 at ~1000m
              const LatLng(0.018, 0.0), // Stop 2 at ~2000m
              const LatLng(0.027, 0.0), // Stop 3 at ~3000m
              const LatLng(0.036, 0.0), // Stop 4 at ~4000m
            ],
            stopMeters: [1000.0, 2000.0, 3000.0, 4000.0],
            lineName: 'Test Line',
            isActualPositions: true,
            stopNames: ['Stop1', 'Stop2', 'Stop3', 'Stop4'],
          ),
        ];

        // Count stops at various positions
        expect(
          TransferUtils.countStopsPassed(transitLegs, 500),
          0,
          reason: 'Before Stop1',
        );
        expect(
          TransferUtils.countStopsPassed(transitLegs, 1500),
          1,
          reason: 'After Stop1, before Stop2',
        );
        expect(
          TransferUtils.countStopsPassed(transitLegs, 2500),
          2,
          reason: 'After Stop2, before Stop3',
        );
        expect(
          TransferUtils.countStopsPassed(transitLegs, 3500),
          3,
          reason: 'After Stop3, before Stop4',
        );
        expect(
          TransferUtils.countStopsPassed(transitLegs, 4500),
          4,
          reason: 'After Stop4, before Transfer',
        );

        // Stops remaining at various positions (toward 5000m)
        // toEventStops = eventStops - progressStops = 4 - progressStops
        expect(
          4 - TransferUtils.countStopsPassed(transitLegs, 500),
          4,
          reason: 'Before Stop1: 4 remaining',
        );
        expect(
          4 - TransferUtils.countStopsPassed(transitLegs, 1500),
          3,
          reason: 'After Stop1: 3 remaining',
        );
        expect(
          4 - TransferUtils.countStopsPassed(transitLegs, 2500),
          2,
          reason: 'After Stop2: 2 remaining',
        );
        expect(
          4 - TransferUtils.countStopsPassed(transitLegs, 3500),
          1,
          reason: 'After Stop3: 1 remaining',
        );
        expect(
          4 - TransferUtils.countStopsPassed(transitLegs, 4500),
          0,
          reason: 'After Stop4: 0 remaining',
        );

        // With threshold = 1 ("1 stop before"), alarm should fire when toEventStops < 1
        // i.e., when toEventStops = 0 (at position after Stop4)
        // Should NOT fire when toEventStops = 1 (at position after Stop3)

        final threshold = 1;

        // At 3500m (after Stop3, toEventStops=1): should NOT fire
        final toEventStopsAt3500 =
            4 - TransferUtils.countStopsPassed(transitLegs, 3500);
        expect(
          toEventStopsAt3500 < threshold,
          false,
          reason: 'At Stop3 (2 stops before): should NOT fire',
        );

        // At 4500m (after Stop4, toEventStops=0): SHOULD fire
        final toEventStopsAt4500 =
            4 - TransferUtils.countStopsPassed(transitLegs, 4500);
        expect(
          toEventStopsAt4500 < threshold,
          true,
          reason: 'At Stop4 (1 stop before): SHOULD fire',
        );
      },
    );

    test('threshold=2 fires at 2 stops before and 1 stop before', () async {
      final transitLegs = [
        TransitLegStops(
          legStartMeters: 0,
          legEndMeters: 5000,
          numStops: 4,
          stopPositions: [
            const LatLng(0.009, 0.0),
            const LatLng(0.018, 0.0),
            const LatLng(0.027, 0.0),
            const LatLng(0.036, 0.0),
          ],
          stopMeters: [1000.0, 2000.0, 3000.0, 4000.0],
          lineName: 'Test Line',
          isActualPositions: true,
          stopNames: ['Stop1', 'Stop2', 'Stop3', 'Stop4'],
        ),
      ];

      final threshold = 2;

      // At 2500m (after Stop2, toEventStops=2): should NOT fire
      final toEventStopsAt2500 =
          4 - TransferUtils.countStopsPassed(transitLegs, 2500);
      expect(
        toEventStopsAt2500 < threshold,
        false,
        reason: 'At Stop2 (3 stops before): should NOT fire',
      );

      // At 3500m (after Stop3, toEventStops=1): SHOULD fire
      final toEventStopsAt3500 =
          4 - TransferUtils.countStopsPassed(transitLegs, 3500);
      expect(
        toEventStopsAt3500 < threshold,
        true,
        reason: 'At Stop3 (2 stops before): SHOULD fire',
      );

      // At 4500m (after Stop4, toEventStops=0): SHOULD fire
      final toEventStopsAt4500 =
          4 - TransferUtils.countStopsPassed(transitLegs, 4500);
      expect(
        toEventStopsAt4500 < threshold,
        true,
        reason: 'At Stop4 (1 stop before): SHOULD fire',
      );
    });

    test('threshold=3 fires at 3, 2, and 1 stops before', () async {
      final transitLegs = [
        TransitLegStops(
          legStartMeters: 0,
          legEndMeters: 5000,
          numStops: 4,
          stopPositions: [
            const LatLng(0.009, 0.0),
            const LatLng(0.018, 0.0),
            const LatLng(0.027, 0.0),
            const LatLng(0.036, 0.0),
          ],
          stopMeters: [1000.0, 2000.0, 3000.0, 4000.0],
          lineName: 'Test Line',
          isActualPositions: true,
          stopNames: ['Stop1', 'Stop2', 'Stop3', 'Stop4'],
        ),
      ];

      final threshold = 3;

      // At 1500m (after Stop1, toEventStops=3): should NOT fire
      final toEventStopsAt1500 =
          4 - TransferUtils.countStopsPassed(transitLegs, 1500);
      expect(
        toEventStopsAt1500 < threshold,
        false,
        reason: 'At Stop1 (4 stops before): should NOT fire',
      );

      // At 2500m (after Stop2, toEventStops=2): SHOULD fire
      final toEventStopsAt2500 =
          4 - TransferUtils.countStopsPassed(transitLegs, 2500);
      expect(
        toEventStopsAt2500 < threshold,
        true,
        reason: 'At Stop2 (3 stops before): SHOULD fire',
      );

      // At 3500m (after Stop3, toEventStops=1): SHOULD fire
      final toEventStopsAt3500 =
          4 - TransferUtils.countStopsPassed(transitLegs, 3500);
      expect(
        toEventStopsAt3500 < threshold,
        true,
        reason: 'At Stop3 (2 stops before): SHOULD fire',
      );

      // At 4500m (after Stop4, toEventStops=0): SHOULD fire
      final toEventStopsAt4500 =
          4 - TransferUtils.countStopsPassed(transitLegs, 4500);
      expect(
        toEventStopsAt4500 < threshold,
        true,
        reason: 'At Stop4 (1 stop before): SHOULD fire',
      );
    });
  });
}
