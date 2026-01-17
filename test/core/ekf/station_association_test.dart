import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/core/ekf/station_association.dart';

void main() {
  group('StationAssociation', () {
    test('selects single candidate within margin window', () {
      final assoc = StationAssociation();
      final result = assoc.selectCandidate(
        stationMeters: const [100.0, 200.0, 300.0],
        sEst: 205.0,
        sigmaS: 10.0,
        isMetroLeg: true,
        zuptConfirmed: true,
        zuptDwell: const Duration(seconds: 25),
      );

      expect(result, isNotNull);
      expect(result!.stationIndex, 1);
    });

    test('rejects when multiple candidates in window', () {
      final assoc = StationAssociation();
      final result = assoc.selectCandidate(
        stationMeters: const [100.0, 200.0, 210.0],
        sEst: 205.0,
        sigmaS: 10.0,
        isMetroLeg: true,
        zuptConfirmed: true,
        zuptDwell: const Duration(seconds: 25),
      );

      expect(result, isNull);
    });

    test('rejects when not metro leg', () {
      final assoc = StationAssociation();
      final result = assoc.selectCandidate(
        stationMeters: const [100.0, 200.0],
        sEst: 100.0,
        sigmaS: 5.0,
        isMetroLeg: false,
        zuptConfirmed: true,
        zuptDwell: const Duration(seconds: 25),
      );

      expect(result, isNull);
    });

    test('rejects when ZUPT dwell not met', () {
      final assoc = StationAssociation();
      final result = assoc.selectCandidate(
        stationMeters: const [100.0],
        sEst: 100.0,
        sigmaS: 5.0,
        isMetroLeg: true,
        zuptConfirmed: true,
        zuptDwell: const Duration(seconds: 5),
      );

      expect(result, isNull);
    });
  });
}
