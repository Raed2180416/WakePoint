// Proof tests for the route/journey-correctness cluster (G14/G15, G16, G18).
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geowake2/services/route_registry.dart';
import 'package:geowake2/services/active_route_manager.dart';
import 'package:geowake2/services/transfer_utils.dart';

void main() {
  group('G14/G15 — wrong-direction / wrong-train detection', () {
    test('sustained on-route regression emits a WrongDirectionAlert (metro leg)',
        () async {
      final reg = RouteRegistry(capacity: 5);
      // Transit route east along the equator (~2.2km). mode 'transit' => metro.
      reg.upsert(RouteEntry(
        key: 'A',
        mode: 'transit',
        destinationName: 'A',
        points: const [LatLng(0, 0), LatLng(0, 0.02)],
      ));

      final mgr = ActiveRouteManager(
        registry: reg,
        sustainDuration: const Duration(milliseconds: 300),
        postSwitchBlackout: const Duration(milliseconds: 50),
        wrongDirectionSustain: const Duration(milliseconds: 100),
        wrongDirectionMinNetRegressionMeters: 60.0,
        onRouteMaxOffsetMeters: 80.0,
      );
      mgr.setActive('A');

      final alerts = <WrongDirectionAlert>[];
      mgr.wrongDirectionStream.listen(alerts.add);

      // Forward baseline (progress increases), all exactly on-route (offset ~0).
      mgr.ingestPosition(const LatLng(0, 0.008)); // ~890m (establishes baseline)
      await Future<void>.delayed(const Duration(milliseconds: 20));
      mgr.ingestPosition(const LatLng(0, 0.010)); // ~1113m forward
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Now regress toward the origin, sustained past 100ms and >60m net.
      mgr.ingestPosition(const LatLng(0, 0.008)); // -223m (start timer)
      await Future<void>.delayed(const Duration(milliseconds: 130));
      mgr.ingestPosition(const LatLng(0, 0.006)); // -222m more -> emit
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(alerts, isNotEmpty,
          reason: 'sustained backward on-route motion must alert');
      expect(alerts.first.isMetro, isTrue);
      expect(alerts.first.netRegressionMeters, greaterThan(60.0));
      mgr.dispose();
    });

    test('normal forward travel never alerts', () async {
      final reg = RouteRegistry(capacity: 5);
      reg.upsert(RouteEntry(
        key: 'A',
        mode: 'transit',
        destinationName: 'A',
        points: const [LatLng(0, 0), LatLng(0, 0.02)],
      ));
      final mgr = ActiveRouteManager(
        registry: reg,
        wrongDirectionSustain: const Duration(milliseconds: 100),
        wrongDirectionMinNetRegressionMeters: 60.0,
      );
      mgr.setActive('A');
      final alerts = <WrongDirectionAlert>[];
      mgr.wrongDirectionStream.listen(alerts.add);

      for (final lon in [0.002, 0.004, 0.006, 0.008, 0.010, 0.012]) {
        mgr.ingestPosition(LatLng(0, lon));
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      expect(alerts, isEmpty, reason: 'monotonic forward travel is correct');
      mgr.dispose();
    });
  });

  group('G16 — OSM vs Google stop-count cross-check', () {
    test('agreement within 20% tolerance does not diverge', () {
      expect(
          TransferUtils.osmStopCountDiverges(apiNumStops: 10, osmNumStops: 10),
          isFalse);
      expect(
          TransferUtils.osmStopCountDiverges(apiNumStops: 10, osmNumStops: 9),
          isFalse); // |1| <= max(1, 2)
    });
    test('large undercount diverges (sparse OSM coverage)', () {
      expect(
          TransferUtils.osmStopCountDiverges(apiNumStops: 10, osmNumStops: 5),
          isTrue); // |5| > 2
    });
    test('zero OSM stops with a real API baseline diverges', () {
      expect(
          TransferUtils.osmStopCountDiverges(apiNumStops: 8, osmNumStops: 0),
          isTrue);
    });
    test('no API baseline => cannot diverge', () {
      expect(
          TransferUtils.osmStopCountDiverges(apiNumStops: 0, osmNumStops: 3),
          isFalse);
    });
  });

  group('G18 — long sleeper journey is NOT refused', () {
    Map<String, dynamic> directionsWithLegs(List<int> legSecs) => {
          'routes': [
            {
              'legs': legSecs
                  .map((s) => {
                        'duration': {'value': s}
                      })
                  .toList()
            }
          ]
        };

    test('an 8-hour single-stop sleeper is well under the 24h ceiling', () {
      final total = TransferUtils.totalPlannedDurationSeconds(
          directionsWithLegs([8 * 3600]));
      expect(total, 8 * 3600);
      expect(total, lessThan(24 * 3600)); // not refused
    });

    test('sums across multiple legs', () {
      final total = TransferUtils.totalPlannedDurationSeconds(
          directionsWithLegs([3 * 3600, 5 * 3600]));
      expect(total, 8 * 3600);
    });

    test('only corrupt >24h data is caught', () {
      final total = TransferUtils.totalPlannedDurationSeconds(
          directionsWithLegs([30 * 3600]));
      expect(total, greaterThan(24 * 3600)); // this is what the ceiling rejects
    });
  });
}
