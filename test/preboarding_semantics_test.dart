import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/alarm_evaluator.dart';
import 'package:geowake2/services/transfer_utils.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

void main() {
  test('PreBoarding only fires on leg directly before metro', () {
    final walk1 = TransitLegStops(
      legStartMeters: 0,
      legEndMeters: 500,
      numStops: 0,
      stopPositions: const [],
      stopMeters: const [],
      lineName: 'Walk segment 1',
      isMetro: false,
      isActualPositions: false,
      stopNames: const [],
    );

    final walk2 = TransitLegStops(
      legStartMeters: 500,
      legEndMeters: 1000,
      numStops: 0,
      stopPositions: const [],
      stopMeters: const [],
      lineName: 'Walk to Station X',
      isMetro: false,
      isActualPositions: false,
      stopNames: const [],
    );

    final metro = TransitLegStops(
      legStartMeters: 1000,
      legEndMeters: 3000,
      numStops: 3,
      stopPositions: const [LatLng(0, 0), LatLng(0, 0), LatLng(0, 0)],
      stopMeters: const [1400, 2000, 2600],
      lineName: 'Green Line',
      isMetro: true,
      isActualPositions: false,
      stopNames: const [],
    );

    final events = <RouteEventBoundary>[
      RouteEventBoundary(
        meters: 1000,
        type: AlarmEventType.preBoarding,
        label: 'Board Green Line',
        associatedLegIndex: 2,
        lat: 0,
        lng: 0,
      ),
    ];

    // At 60% of walk1, the next leg is still non-metro (walk2) => no preBoarding.
    final r1 = AlarmEvaluator.evaluateCoinciding(
      mode: AlarmMode.stops,
      userValue: 2.0,
      progressMeters: 300.0,
      allEvents: events,
      firedEventIndexes: {},
      firedLegIds: {},
      isMetroLeg: false,
      transitLegs: [walk1, walk2, metro],
      currentLegIndex: 0,
      isFinalLeg: false,
    );
    expect(r1, isNull);

    // At 60% of walk2, the next leg is metro => preBoarding, and message should
    // prefer the explicit preBoarding label.
    final r2 = AlarmEvaluator.evaluateCoinciding(
      mode: AlarmMode.stops,
      userValue: 2.0,
      progressMeters: 800.0,
      allEvents: events,
      firedEventIndexes: {},
      firedLegIds: {},
      isMetroLeg: false,
      transitLegs: [walk1, walk2, metro],
      currentLegIndex: 1,
      isFinalLeg: false,
    );

    expect(r2, isNotNull);
    expect(r2!.eventType, equals(AlarmEventType.preBoarding));
    expect(r2.message, equals('Approaching metro station: Board Green Line'));
  });
}
