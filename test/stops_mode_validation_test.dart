import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/stop_logic_engine.dart';
import 'package:geowake2/services/transfer_utils.dart';

/// Tests for two critical stops-mode rules:
///
/// 1. VALIDATION RULE: User cannot choose N >= min(stops across all metro legs)
///    This ensures every metro leg can meaningfully fire an alarm.
///
/// 2. ZERO-INTERMEDIATE-STOPS EDGE CASE: If a metro leg has no intermediate stops
///    (only boarding → alighting), fire alarm immediately at switchpoint since
///    there's only 1 stop remaining (the target/alighting point).

void main() {
  group('Stops Mode Validation Rules', () {
    late StopLogicEngine engine;

    setUp(() {
      engine = StopLogicEngine();
    });

    // =========================================================================
    // RULE 1: validateThresholdAgainstMetroLegs
    // User cannot choose N >= min(stops across all metro legs)
    // =========================================================================

    group('Rule 1: Threshold validation against minimum metro leg stops', () {
      test('allows threshold < min stops on all metro legs', () {
        final legs = [
          TransitLegStops(
            legStartMeters: 0,
            legEndMeters: 5000,
            numStops: 4, // 4 intermediate stops → 5 total (incl. target)
            stopPositions: [],
            stopMeters: [],
            lineName: 'Green Line',
            isMetro: true,
          ),
          TransitLegStops(
            legStartMeters: 5000,
            legEndMeters: 10000,
            numStops: 6, // 6 intermediate stops → 7 total
            stopPositions: [],
            stopMeters: [],
            lineName: 'Purple Line',
            isMetro: true,
          ),
        ];

        // Min stops = 5 (Green Line: 4 intermediate + 1 target)
        // User threshold 4 < 5 → valid
        final result = engine.validateThresholdAgainstMetroLegs(
          userThreshold: 4,
          transitLegs: legs,
        );

        expect(result.isValid, isTrue);
        expect(result.minMetroStops, 5);
      });

      test('rejects threshold >= min stops on any metro leg', () {
        final legs = [
          TransitLegStops(
            legStartMeters: 0,
            legEndMeters: 5000,
            numStops: 2, // 2 intermediate → 3 total stops
            stopPositions: [],
            stopMeters: [],
            lineName: 'Short Metro',
            isMetro: true,
          ),
          TransitLegStops(
            legStartMeters: 5000,
            legEndMeters: 15000,
            numStops: 10, // 10 intermediate → 11 total
            stopPositions: [],
            stopMeters: [],
            lineName: 'Long Metro',
            isMetro: true,
          ),
        ];

        // Min stops = 3 (Short Metro: 2 intermediate + 1 target)
        // User threshold 3 >= 3 → invalid
        final result3 = engine.validateThresholdAgainstMetroLegs(
          userThreshold: 3,
          transitLegs: legs,
        );
        expect(result3.isValid, isFalse);
        expect(result3.errorMessage, contains('Short Metro'));
        expect(result3.errorMessage, contains('3'));

        // User threshold 4 >= 3 → invalid
        final result4 = engine.validateThresholdAgainstMetroLegs(
          userThreshold: 4,
          transitLegs: legs,
        );
        expect(result4.isValid, isFalse);
      });

      test('allows threshold 1 when min stops is 2', () {
        final legs = [
          TransitLegStops(
            legStartMeters: 0,
            legEndMeters: 1000,
            numStops: 1, // 1 intermediate stop → 2 total
            stopPositions: [],
            stopMeters: [],
            lineName: 'Mini Metro',
            isMetro: true,
          ),
        ];

        // Min stops = 2 (1 intermediate + 1 target)
        // User threshold 1 < 2 → valid
        final result = engine.validateThresholdAgainstMetroLegs(
          userThreshold: 1,
          transitLegs: legs,
        );

        expect(result.isValid, isTrue);
        expect(result.minMetroStops, 2);
      });

      test(
        'rejects threshold 2 when a metro leg has only 1 intermediate stop',
        () {
          final legs = [
            TransitLegStops(
              legStartMeters: 0,
              legEndMeters: 1000,
              numStops: 1, // 1 intermediate → 2 total
              stopPositions: [],
              stopMeters: [],
              lineName: 'Mini Metro',
              isMetro: true,
            ),
          ];

          // Min stops = 2
          // User threshold 2 >= 2 → invalid
          final result = engine.validateThresholdAgainstMetroLegs(
            userThreshold: 2,
            transitLegs: legs,
          );

          expect(result.isValid, isFalse);
          expect(result.errorMessage, contains('Mini Metro'));
        },
      );

      test('ignores non-metro legs when computing minimum', () {
        final legs = [
          TransitLegStops(
            legStartMeters: 0,
            legEndMeters: 500,
            numStops: 0, // Walk leg - no stops
            stopPositions: [],
            stopMeters: [],
            lineName: 'Walk',
            isMetro: false,
          ),
          TransitLegStops(
            legStartMeters: 500,
            legEndMeters: 5000,
            numStops: 5, // 6 total stops
            stopPositions: [],
            stopMeters: [],
            lineName: 'Green Line',
            isMetro: true,
          ),
          TransitLegStops(
            legStartMeters: 5000,
            legEndMeters: 5200,
            numStops: 0, // Walk leg
            stopPositions: [],
            stopMeters: [],
            lineName: 'Walk to station',
            isMetro: false,
          ),
        ];

        // Only the Green Line is metro - 6 total stops
        // User threshold 5 < 6 → valid
        final result = engine.validateThresholdAgainstMetroLegs(
          userThreshold: 5,
          transitLegs: legs,
        );

        expect(result.isValid, isTrue);
        expect(result.minMetroStops, 6);
      });

      test('returns valid when no metro legs exist', () {
        final legs = [
          TransitLegStops(
            legStartMeters: 0,
            legEndMeters: 500,
            numStops: 0,
            stopPositions: [],
            stopMeters: [],
            lineName: 'Walk',
            isMetro: false,
          ),
          TransitLegStops(
            legStartMeters: 500,
            legEndMeters: 3000,
            numStops: 5,
            stopPositions: [],
            stopMeters: [],
            lineName: 'Bus 401-A',
            isMetro: false,
          ),
        ];

        // No metro legs → validation passes for any threshold
        final result = engine.validateThresholdAgainstMetroLegs(
          userThreshold: 10,
          transitLegs: legs,
        );

        expect(result.isValid, isTrue);
      });

      test('handles edge case: metro leg with 0 intermediate stops', () {
        final legs = [
          TransitLegStops(
            legStartMeters: 0,
            legEndMeters: 2000,
            numStops: 0, // 0 intermediate → 1 total (just target)
            stopPositions: [],
            stopMeters: [],
            lineName: 'Express Metro',
            isMetro: true,
          ),
        ];

        // Min stops = 1 (0 intermediate + 1 target)
        // User threshold 1 >= 1 → invalid
        final result = engine.validateThresholdAgainstMetroLegs(
          userThreshold: 1,
          transitLegs: legs,
        );

        expect(result.isValid, isFalse);
        expect(result.minMetroStops, 1);
        expect(result.errorMessage, contains('Express Metro'));
        expect(result.errorMessage, contains('1 stop'));
      });

      test('multi-metro route finds correct minimum', () {
        final legs = [
          TransitLegStops(
            legStartMeters: 0,
            legEndMeters: 300,
            numStops: 0,
            stopPositions: [],
            stopMeters: [],
            lineName: 'Walk',
            isMetro: false,
          ),
          TransitLegStops(
            legStartMeters: 300,
            legEndMeters: 5000,
            numStops: 10, // Green Line: 11 total
            stopPositions: [],
            stopMeters: [],
            lineName: 'Green Line',
            isMetro: true,
          ),
          TransitLegStops(
            legStartMeters: 5000,
            legEndMeters: 5100,
            numStops: 0,
            stopPositions: [],
            stopMeters: [],
            lineName: 'Walk interchange',
            isMetro: false,
          ),
          TransitLegStops(
            legStartMeters: 5100,
            legEndMeters: 20000,
            numStops: 20, // Purple Line: 21 total
            stopPositions: [],
            stopMeters: [],
            lineName: 'Purple Line',
            isMetro: true,
          ),
          TransitLegStops(
            legStartMeters: 20000,
            legEndMeters: 20200,
            numStops: 0,
            stopPositions: [],
            stopMeters: [],
            lineName: 'Walk',
            isMetro: false,
          ),
          TransitLegStops(
            legStartMeters: 20200,
            legEndMeters: 22000,
            numStops: 3, // Blue Line: 4 total ← THIS IS THE MINIMUM
            stopPositions: [],
            stopMeters: [],
            lineName: 'Blue Line',
            isMetro: true,
          ),
        ];

        // Min stops = 4 (Blue Line: 3 intermediate + 1 target)
        final result3 = engine.validateThresholdAgainstMetroLegs(
          userThreshold: 3,
          transitLegs: legs,
        );
        expect(result3.isValid, isTrue);
        expect(result3.minMetroStops, 4);

        // Threshold 4 >= 4 → invalid
        final result4 = engine.validateThresholdAgainstMetroLegs(
          userThreshold: 4,
          transitLegs: legs,
        );
        expect(result4.isValid, isFalse);
        expect(result4.errorMessage, contains('Blue Line'));
      });
    });

    // =========================================================================
    // RULE 2: Zero-intermediate-stops alarm behavior
    // Fire immediately at switchpoint when entering a metro leg with 0 intermediate stops
    // The actual alarm evaluation is done via AlarmEvaluator.evaluateCoinciding
    // which uses the StopLogicEngine internally.
    // These tests verify the validation logic correctly handles zero-stop edges.
    // =========================================================================

    group('Rule 2: Zero-intermediate-stops validation and edge cases', () {
      test('validation rejects all thresholds for zero-stop metro legs', () {
        // A metro leg with 0 intermediate stops has only 1 total stop (the target).
        // This means NO threshold value is valid, since even threshold=1 would equal total stops.
        final legs = [
          TransitLegStops(
            legStartMeters: 0,
            legEndMeters: 500,
            numStops: 0,
            stopPositions: [],
            stopMeters: [],
            lineName: 'Walk',
            isMetro: false,
          ),
          TransitLegStops(
            legStartMeters: 500,
            legEndMeters: 3000,
            numStops: 0, // Express metro - no intermediate stops
            stopPositions: [],
            stopMeters: [],
            lineName: 'Express Metro',
            isMetro: true,
          ),
        ];

        // threshold 1 >= 1 → invalid
        final result1 = engine.validateThresholdAgainstMetroLegs(
          userThreshold: 1,
          transitLegs: legs,
        );
        expect(result1.isValid, isFalse);
        expect(result1.minMetroStops, 1);
        expect(result1.errorMessage, contains('Express Metro'));
      });

      test(
        'zero-stop metro mixed with normal metro uses zero-stop minimum',
        () {
          final legs = [
            TransitLegStops(
              legStartMeters: 0,
              legEndMeters: 5000,
              numStops: 8, // 9 total stops
              stopPositions: [],
              stopMeters: [],
              lineName: 'Green Line',
              isMetro: true,
            ),
            TransitLegStops(
              legStartMeters: 5000,
              legEndMeters: 5100,
              numStops: 0,
              stopPositions: [],
              stopMeters: [],
              lineName: 'Walk',
              isMetro: false,
            ),
            TransitLegStops(
              legStartMeters: 5100,
              legEndMeters: 7000,
              numStops: 0, // 1 total stop - THE CONSTRAINT
              stopPositions: [],
              stopMeters: [],
              lineName: 'Express Line',
              isMetro: true,
            ),
          ];

          // min stops = 1 (Express Line)
          // Even threshold=1 is invalid
          final result = engine.validateThresholdAgainstMetroLegs(
            userThreshold: 1,
            transitLegs: legs,
          );
          expect(result.isValid, isFalse);
          expect(result.minMetroStops, 1);
          expect(result.errorMessage, contains('Express Line'));
        },
      );

      test(
        'validation correctly counts total stops (intermediate + 1 target)',
        () {
          // numStops is intermediate only, total = numStops + 1 (the alighting point)
          final legs = [
            TransitLegStops(
              legStartMeters: 0,
              legEndMeters: 5000,
              numStops: 3, // 3 intermediate + 1 target = 4 total
              stopPositions: [],
              stopMeters: [],
              lineName: 'Metro A',
              isMetro: true,
            ),
          ];

          // threshold 3 < 4 → valid
          final result3 = engine.validateThresholdAgainstMetroLegs(
            userThreshold: 3,
            transitLegs: legs,
          );
          expect(result3.isValid, isTrue);
          expect(result3.minMetroStops, 4);

          // threshold 4 >= 4 → invalid
          final result4 = engine.validateThresholdAgainstMetroLegs(
            userThreshold: 4,
            transitLegs: legs,
          );
          expect(result4.isValid, isFalse);
        },
      );

      test('empty list of transit legs returns valid', () {
        final result = engine.validateThresholdAgainstMetroLegs(
          userThreshold: 5,
          transitLegs: [],
        );

        expect(result.isValid, isTrue);
      });
    });
  });
}
