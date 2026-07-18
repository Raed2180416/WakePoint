import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/data_asset/od_cell.dart';
import 'package:geowake2/services/data_asset/station_binner.dart';

void main() {
  // A tiny deterministic catalogue: two stations ~far apart.
  final binner = StationBinner.fromEntries([
    (id: 'S_A', lat: 12.9716, lng: 77.5946), // Bengaluru-ish
    (id: 'S_B', lat: 12.9352, lng: 77.6245),
  ]);

  // Monday 2024-01-01 08:10 UTC. tzOffset +330 (IST) -> local 13:40 Mon.
  const mondayEpochMs = 1704096600000; // 2024-01-01T08:10:00Z
  const istOffset = 330;

  group('StationBinner', () {
    test('snaps a nearby fix to the correct catalogue token', () {
      final ep = binner.bin(
        lat: 12.9717,
        lng: 77.5947,
        epochMs: mondayEpochMs,
        tzOffsetMinutes: istOffset,
      );
      expect(ep, isNotNull);
      expect(ep!.stationId, 'S_A');
    });

    test('computes local hourBin and dayType from tz offset', () {
      final ep = binner.bin(
        lat: 12.9716,
        lng: 77.5946,
        epochMs: mondayEpochMs,
        tzOffsetMinutes: istOffset,
      )!;
      // 08:10Z + 5:30 = 13:40 local Monday.
      expect(ep.hourBin, 13);
      expect(ep.dayType, DayType.weekday);
    });

    test('weekend detection', () {
      // 2024-01-06 is a Saturday.
      const satEpoch = 1704528000000; // 2024-01-06T08:00:00Z -> 13:30 IST Sat
      final ep = binner.bin(
        lat: 12.9716,
        lng: 77.5946,
        epochMs: satEpoch,
        tzOffsetMinutes: istOffset,
      )!;
      expect(ep.dayType, DayType.weekend);
    });

    test('returns null when no station within max radius (R1: dropped=safe)', () {
      final ep = binner.bin(
        lat: 28.6139, // New Delhi — nowhere near the catalogue
        lng: 77.2090,
        epochMs: mondayEpochMs,
        tzOffsetMinutes: istOffset,
      );
      expect(ep, isNull);
    });

    test('every emitted token is a member of the catalogue set (R1)', () {
      final ep = binner.bin(
        lat: 12.9352,
        lng: 77.6245,
        epochMs: mondayEpochMs,
        tzOffsetMinutes: istOffset,
      )!;
      expect(binner.catalogueIds.contains(ep.stationId), isTrue);
    });

    test('shipped catalogue binner yields only catalogue tokens', () {
      final shipped = StationBinner.fromShippedCatalogue();
      expect(shipped.catalogueIds, isNotEmpty);
      // A fix near a real shipped station must snap to a catalogue member.
      final ep = shipped.bin(
        lat: 12.9716,
        lng: 77.5946,
        epochMs: mondayEpochMs,
        tzOffsetMinutes: istOffset,
      );
      if (ep != null) {
        expect(shipped.catalogueIds.contains(ep.stationId), isTrue);
      }
    });

    test('TripEndpoint carries no coordinate-shaped field', () {
      final ep = binner.bin(
        lat: 12.9716,
        lng: 77.5946,
        epochMs: mondayEpochMs,
        tzOffsetMinutes: istOffset,
      )!;
      // Only these three fields exist; the toString has no lat/lng number.
      expect(ep.toString().toLowerCase().contains('lat'), isFalse);
      expect(ep.toString().toLowerCase().contains('lng'), isFalse);
    });
  });
}
