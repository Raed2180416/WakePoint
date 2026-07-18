// Pure-logic tests for TripStatsSummary — no Flutter bindings needed.
import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/stats/trip_record.dart';
import 'package:geowake2/services/stats/trip_stats_summary.dart';

TripRecord _rec(
  DateTime at, {
  bool onTime = true,
  String? line,
  String? station,
}) {
  return TripRecord.build(
    mode: 'stops',
    outcome: onTime ? 'onTime' : 'late',
    completedAtMs: at.millisecondsSinceEpoch,
    line: line,
    destStation: station,
    wokenOnTime: onTime,
  );
}

void main() {
  group('TripStatsSummary.compute', () {
    test('empty input → empty summary', () {
      final s = TripStatsSummary.compute(const []);
      expect(s.totalTrips, 0);
      expect(s.currentStreakDays, 0);
      expect(s.longestStreakDays, 0);
      expect(s.hourHistogram.length, 24);
      expect(s.favoriteLine, isNull);
      expect(s.busiestHour, isNull);
    });

    test('month vs lifetime on-time counts', () {
      final now = DateTime(2026, 7, 19, 9);
      final s = TripStatsSummary.compute([
        _rec(DateTime(2026, 7, 1, 8)), // this month, on time
        _rec(DateTime(2026, 7, 5, 8), onTime: false), // this month, late
        _rec(DateTime(2026, 6, 20, 8)), // last month, on time
      ], now: now);
      expect(s.totalTrips, 3);
      expect(s.monthTrips, 2);
      expect(s.monthWokenOnTime, 1);
      expect(s.lifetimeWokenOnTime, 2);
    });

    test('current streak counts consecutive days ending today', () {
      final now = DateTime(2026, 7, 19, 23);
      final s = TripStatsSummary.compute([
        _rec(DateTime(2026, 7, 19, 8)),
        _rec(DateTime(2026, 7, 18, 8)),
        _rec(DateTime(2026, 7, 17, 8)),
        _rec(DateTime(2026, 7, 15, 8)), // gap on the 16th breaks the run
      ], now: now);
      expect(s.currentStreakDays, 3);
    });

    test('current streak still counts when the run ends yesterday', () {
      final now = DateTime(2026, 7, 19, 7);
      final s = TripStatsSummary.compute([
        _rec(DateTime(2026, 7, 18, 8)),
        _rec(DateTime(2026, 7, 17, 8)),
      ], now: now);
      expect(s.currentStreakDays, 2);
    });

    test('current streak is zero when the last trip is stale', () {
      final now = DateTime(2026, 7, 19);
      final s = TripStatsSummary.compute([
        _rec(DateTime(2026, 7, 10, 8)),
      ], now: now);
      expect(s.currentStreakDays, 0);
    });

    test('longest streak >= current and is found anywhere in history', () {
      final now = DateTime(2026, 7, 19);
      final s = TripStatsSummary.compute([
        // A 4-day run in the past.
        _rec(DateTime(2026, 7, 1)),
        _rec(DateTime(2026, 7, 2)),
        _rec(DateTime(2026, 7, 3)),
        _rec(DateTime(2026, 7, 4)),
        // A 1-day "current".
        _rec(DateTime(2026, 7, 19)),
      ], now: now);
      expect(s.longestStreakDays, 4);
      expect(s.currentStreakDays, 1);
      expect(s.longestStreakDays, greaterThanOrEqualTo(s.currentStreakDays));
    });

    test('top lines ranked by frequency, capped at 5', () {
      final now = DateTime(2026, 7, 19);
      final s = TripStatsSummary.compute([
        _rec(now, line: 'Purple'),
        _rec(now, line: 'Purple'),
        _rec(now, line: 'Green'),
        _rec(now, line: 'Blue'),
        _rec(now, line: 'Red'),
        _rec(now, line: 'Yellow'),
        _rec(now, line: 'Pink'),
      ], now: now);
      expect(s.topLines.length, 5);
      expect(s.favoriteLine!.line, 'Purple');
      expect(s.favoriteLine!.count, 2);
    });

    test('distinct stations counts unique names only', () {
      final now = DateTime(2026, 7, 19);
      final s = TripStatsSummary.compute([
        _rec(now, station: 'Indiranagar'),
        _rec(now, station: 'Indiranagar'),
        _rec(now, station: 'MG Road'),
      ], now: now);
      expect(s.distinctStations, 2);
    });

    test('busiest hour reflects the histogram', () {
      final now = DateTime(2026, 7, 19);
      final s = TripStatsSummary.compute([
        _rec(DateTime(2026, 7, 1, 9)),
        _rec(DateTime(2026, 7, 2, 9)),
        _rec(DateTime(2026, 7, 3, 18)),
      ], now: now);
      expect(s.busiestHour, 9);
      expect(s.hourHistogram[9], 2);
      expect(s.hourHistogram[18], 1);
    });
  });
}
