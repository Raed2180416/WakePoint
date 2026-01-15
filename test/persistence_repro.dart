import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/transfer_utils.dart';
// Verified: logic handles persistence survival of isActualPositions
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'dart:convert';

void main() {
  test('TransitLegStops Persistence: OSM Data Survival', () {
    // 1. Create "Enhanced" Leg (Source of Truth)
    // This simulates what happens after TransferUtils.enhanceTransitLegStopsWithOsm()
    final originalLeg = TransitLegStops(
      legStartMeters: 0,
      legEndMeters: 1000,
      numStops: 3,
      lineName: 'Purple Line',
      stopMeters: [0, 500, 1000],
      stopNames: ['Station A', 'Station B', 'Station C'],
      stopPositions: [
        const LatLng(12.0, 77.0),
        const LatLng(12.1, 77.1),
        const LatLng(12.2, 77.2),
      ],
      isMetro: true,
      isActualPositions: true, // CRITICAL FLAG
    );

    print(
      'Original: isActual=${originalLeg.isActualPositions}, stops=${originalLeg.stopNames}',
    );

    // 2. Serialize (toJson)
    final jsonMap = originalLeg.toJson();
    final jsonString = jsonEncode(jsonMap);
    print('JSON: $jsonString');

    // 3. Deserialize (fromJson)
    final decodedMap = jsonDecode(jsonString);
    final restoredLeg = TransitLegStops.fromJson(decodedMap);

    print(
      'Restored: isActual=${restoredLeg.isActualPositions}, stops=${restoredLeg.stopNames}',
    );

    // 4. Verify Integrity
    expect(
      restoredLeg.isActualPositions,
      isTrue,
      reason: 'isActualPositions flag lost!',
    );
    expect(restoredLeg.stopNames.length, equals(3), reason: 'Stop names lost!');
    expect(
      restoredLeg.stopNames[1],
      equals('Station B'),
      reason: 'Stop name corrupted',
    );
    expect(
      restoredLeg.stopPositions.length,
      equals(3),
      reason: 'Stop positions lost!',
    );
    expect(
      restoredLeg.stopPositions[0].latitude,
      equals(12.0),
      reason: 'Lat corrupted',
    );

    // 5. Verify Leg ID Stability across persistence
    expect(
      restoredLeg.legId,
      equals(originalLeg.legId),
      reason: 'Leg ID changed after save/load!',
    );
  });
}
