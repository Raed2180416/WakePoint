// test/metro_data_integrity_test.dart
//
// BACKLOG #12: Runtime/CI validation gate on the SHIPPED Dart metro data.
//
// The shipped constants `kMetroLineSequences` (lib/data/metro_line_sequences.dart)
// and `allIndiaStops` (lib/all_india_stops.dart) previously had ZERO assert/schema
// coverage — the only validator audited an UNSHIPPED JSON asset that is never
// bundled or `rootBundle`-loaded, so the real data was free to drift.
//
// This is a pure `flutter test` gate over the actual shipped constants. It fails
// LOUDLY (listing every offending line/stop) on drift so a bad data regen cannot
// merge silently and mis-fire a rider's alarm.
//
// Invariants asserted:
//   1. India bbox — every coordinate in both datasets lies inside
//      lat 6.0..37.5, lng 68.0..98.0.
//   2. Each ordered line sequence has >= 2 stops.
//   3. No <40 m consecutive duplicate stations within a sequence.
//   4. Dense-line hop ceiling — sequences with >= 3 stops have no consecutive
//      hop > 6 km (a mis-ordered/teleported interior stop shows up as a big hop).
//   5. Gross cross-city drift ceiling — NO sequence (including sparse 2-stop
//      RRTS/express termini legitimately spaced ~22 km apart) has a hop > 30 km;
//      a station accidentally geocoded into another city (>100 km away) fails.
//   6. Ordering sanity — no station NAME repeats within a single sequence.
//   7. Key resolution — every city key in kMetroLineSequences also exists as a
//      city in allIndiaStops, and every city maps to >= 1 non-empty line key.
//
// Thresholds are grounded in the current shipped data (max dense hop ~3.4 km in
// Kochi; the only >6 km hops are the 2-stop Delhi-Meerut RRTS ~22.4 km and the
// 2-stop partial Agra Blue ~9.9 km termini; min consecutive spacing ~157 m).

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/data/metro_line_sequences.dart';
import 'package:geowake2/all_india_stops.dart';

// India bounding box (generous mainland + islands margin).
const double _minLat = 6.0;
const double _maxLat = 37.5;
const double _minLng = 68.0;
const double _maxLng = 98.0;

// Hop thresholds (meters).
const double _minConsecutiveMeters = 40.0; // below => duplicate station
const double _denseHopCeilingMeters = 6000.0; // for sequences with >= 3 stops
const double _grossHopCeilingMeters = 30000.0; // for ALL sequences (drift catch)

double _haversineMeters(double lat1, double lng1, double lat2, double lng2) {
  const earthRadius = 6371000.0;
  final dLat = _deg2rad(lat2 - lat1);
  final dLng = _deg2rad(lng2 - lng1);
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(_deg2rad(lat1)) *
          math.cos(_deg2rad(lat2)) *
          math.sin(dLng / 2) *
          math.sin(dLng / 2);
  final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  return earthRadius * c;
}

double _deg2rad(double d) => d * math.pi / 180.0;

bool _inIndiaBbox(double lat, double lng) =>
    lat >= _minLat && lat <= _maxLat && lng >= _minLng && lng <= _maxLng;

void main() {
  group('kMetroLineSequences integrity', () {
    test('every coordinate is inside the India bbox', () {
      final violations = <String>[];
      kMetroLineSequences.forEach((city, lines) {
        lines.forEach((line, stops) {
          for (final s in stops) {
            if (!_inIndiaBbox(s.lat, s.lng)) {
              violations.add(
                '$city/$line "${s.name}" @ (${s.lat}, ${s.lng})',
              );
            }
          }
        });
      });
      expect(
        violations,
        isEmpty,
        reason: 'Out-of-India coordinates:\n${violations.join('\n')}',
      );
    });

    test('every sequence has at least 2 ordered stops', () {
      final violations = <String>[];
      kMetroLineSequences.forEach((city, lines) {
        lines.forEach((line, stops) {
          if (stops.length < 2) {
            violations.add('$city/$line has ${stops.length} stop(s)');
          }
        });
      });
      expect(
        violations,
        isEmpty,
        reason: 'Degenerate sequences:\n${violations.join('\n')}',
      );
    });

    test('no <40 m consecutive duplicate stations', () {
      final violations = <String>[];
      kMetroLineSequences.forEach((city, lines) {
        lines.forEach((line, stops) {
          for (var i = 1; i < stops.length; i++) {
            final a = stops[i - 1];
            final b = stops[i];
            final d = _haversineMeters(a.lat, a.lng, b.lat, b.lng);
            if (d < _minConsecutiveMeters) {
              violations.add(
                '$city/$line "${a.name}" -> "${b.name}" '
                'only ${d.toStringAsFixed(1)} m apart',
              );
            }
          }
        });
      });
      expect(
        violations,
        isEmpty,
        reason: 'Near-duplicate consecutive stations:\n${violations.join('\n')}',
      );
    });

    test('dense lines (>=3 stops) have no consecutive hop > 6 km', () {
      final violations = <String>[];
      kMetroLineSequences.forEach((city, lines) {
        lines.forEach((line, stops) {
          if (stops.length < 3) return; // sparse termini-only legs exempted
          for (var i = 1; i < stops.length; i++) {
            final a = stops[i - 1];
            final b = stops[i];
            final d = _haversineMeters(a.lat, a.lng, b.lat, b.lng);
            if (d > _denseHopCeilingMeters) {
              violations.add(
                '$city/$line "${a.name}" -> "${b.name}" '
                '= ${(d / 1000).toStringAsFixed(2)} km',
              );
            }
          }
        });
      });
      expect(
        violations,
        isEmpty,
        reason: 'Suspicious large intra-line hops (possible mis-order/drift):\n'
            '${violations.join('\n')}',
      );
    });

    test('no sequence has a consecutive hop > 30 km (cross-city drift)', () {
      final violations = <String>[];
      kMetroLineSequences.forEach((city, lines) {
        lines.forEach((line, stops) {
          for (var i = 1; i < stops.length; i++) {
            final a = stops[i - 1];
            final b = stops[i];
            final d = _haversineMeters(a.lat, a.lng, b.lat, b.lng);
            if (d > _grossHopCeilingMeters) {
              violations.add(
                '$city/$line "${a.name}" -> "${b.name}" '
                '= ${(d / 1000).toStringAsFixed(1)} km',
              );
            }
          }
        });
      });
      expect(
        violations,
        isEmpty,
        reason: 'A station appears geocoded into another city:\n'
            '${violations.join('\n')}',
      );
    });

    test('no repeated station name within a single sequence (ordering)', () {
      final violations = <String>[];
      kMetroLineSequences.forEach((city, lines) {
        lines.forEach((line, stops) {
          final seen = <String>{};
          for (final s in stops) {
            final key = s.name.trim().toLowerCase();
            if (!seen.add(key)) {
              violations.add('$city/$line repeats "${s.name}"');
            }
          }
        });
      });
      expect(
        violations,
        isEmpty,
        reason: 'Repeated stations (disordered/corrupt sequence):\n'
            '${violations.join('\n')}',
      );
    });
  });

  group('allIndiaStops integrity', () {
    test('every stop has a valid India-bbox coordinate', () {
      final violations = <String>[];
      for (final stop in allIndiaStops) {
        final lat = (stop['lat'] as num?)?.toDouble();
        final lng = (stop['lng'] as num?)?.toDouble();
        final name = stop['name'];
        if (lat == null || lng == null) {
          violations.add('${stop['id']} "$name" missing lat/lng');
          continue;
        }
        if (!_inIndiaBbox(lat, lng)) {
          violations.add('${stop['id']} "$name" @ ($lat, $lng)');
        }
      }
      expect(
        violations,
        isEmpty,
        reason: 'Out-of-India / malformed stops:\n${violations.join('\n')}',
      );
    });

    test('every stop carries a non-empty city and name', () {
      final violations = <String>[];
      for (final stop in allIndiaStops) {
        final city = (stop['city'] as String?)?.trim() ?? '';
        final name = (stop['name'] as String?)?.trim() ?? '';
        if (city.isEmpty || name.isEmpty) {
          violations.add('${stop['id']} city="$city" name="$name"');
        }
      }
      expect(
        violations,
        isEmpty,
        reason: 'Stops with empty city/name:\n${violations.join('\n')}',
      );
    });
  });

  group('cross-dataset key resolution', () {
    test('every sequence city + line key resolves', () {
      final knownCities = allIndiaStops
          .map((s) => (s['city'] as String?)?.trim().toLowerCase() ?? '')
          .where((c) => c.isNotEmpty)
          .toSet();

      final violations = <String>[];
      kMetroLineSequences.forEach((city, lines) {
        if (city.trim().isEmpty) {
          violations.add('empty city key in kMetroLineSequences');
        } else if (!knownCities.contains(city.toLowerCase())) {
          violations.add(
            'city "$city" has ordered sequences but no stops in allIndiaStops',
          );
        }
        if (lines.isEmpty) {
          violations.add('city "$city" maps to zero lines');
        }
        lines.forEach((line, stops) {
          if (line.trim().isEmpty) {
            violations.add('city "$city" has an empty line key');
          }
        });
      });
      expect(
        violations,
        isEmpty,
        reason: 'Unresolvable city/line keys:\n${violations.join('\n')}',
      );
    });
  });
}
