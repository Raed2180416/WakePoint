// lib/services/stats/trip_stats_summary.dart
//
// Pure aggregation over a list of [TripRecord]s. No Flutter, no I/O, injected
// `now` — so every number (streaks, histograms, top lines) is deterministically
// unit-testable and DST-safe.
//
// The FREE growth-loop surfaces read `monthWokenOnTime` / `lifetimeWokenOnTime`;
// the PRO dashboard reads the streaks / histogram / top-lines fields.
library;

import 'package:geowake2/services/stats/trip_record.dart';

class TopLine {
  final String line;
  final int count;
  const TopLine(this.line, this.count);
}

/// Immutable rollup of the trip ledger.
class TripStatsSummary {
  final int totalTrips;
  final int monthTrips;
  final int monthWokenOnTime;
  final int lifetimeWokenOnTime;

  /// Consecutive days (ending today or yesterday) with >=1 completed trip.
  final int currentStreakDays;

  /// Longest consecutive-day run ever recorded.
  final int longestStreakDays;

  /// 24-bucket local hour-of-day histogram (index 0..23).
  final List<int> hourHistogram;

  /// Up to 5 most-travelled named lines, most-frequent first.
  final List<TopLine> topLines;

  /// Distinct named destination stations seen.
  final int distinctStations;

  const TripStatsSummary({
    required this.totalTrips,
    required this.monthTrips,
    required this.monthWokenOnTime,
    required this.lifetimeWokenOnTime,
    required this.currentStreakDays,
    required this.longestStreakDays,
    required this.hourHistogram,
    required this.topLines,
    required this.distinctStations,
  });

  static const TripStatsSummary empty = TripStatsSummary(
    totalTrips: 0,
    monthTrips: 0,
    monthWokenOnTime: 0,
    lifetimeWokenOnTime: 0,
    currentStreakDays: 0,
    longestStreakDays: 0,
    hourHistogram: <int>[
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    ],
    topLines: <TopLine>[],
    distinctStations: 0,
  );

  /// The single most-used line, or null if no line was ever named.
  TopLine? get favoriteLine => topLines.isEmpty ? null : topLines.first;

  /// The busiest local hour [0..23], or null if there are no trips.
  int? get busiestHour {
    var best = -1;
    var bestCount = 0;
    for (var h = 0; h < 24; h++) {
      if (hourHistogram[h] > bestCount) {
        bestCount = hourHistogram[h];
        best = h;
      }
    }
    return best < 0 ? null : best;
  }

  /// Compute a summary from [records] as of [now] (defaults to wall clock).
  factory TripStatsSummary.compute(
    List<TripRecord> records, {
    DateTime? now,
  }) {
    if (records.isEmpty) return empty;
    final asOf = now ?? DateTime.now();

    var monthTrips = 0;
    var monthOnTime = 0;
    var lifetimeOnTime = 0;
    final hist = List<int>.filled(24, 0);
    final lineCounts = <String, int>{};
    final stations = <String>{};
    final dayNums = <int>{};

    for (final r in records) {
      final local = DateTime.fromMillisecondsSinceEpoch(r.completedAtMs);
      if (r.wokenOnTime) lifetimeOnTime++;
      if (local.year == asOf.year && local.month == asOf.month) {
        monthTrips++;
        if (r.wokenOnTime) monthOnTime++;
      }
      final h = r.hourOfDay;
      if (h >= 0 && h < 24) hist[h]++;
      final line = r.line;
      if (line != null && line.isNotEmpty) {
        lineCounts[line] = (lineCounts[line] ?? 0) + 1;
      }
      final st = r.destStation;
      if (st != null && st.isNotEmpty) stations.add(st);
      dayNums.add(_dayNumber(local));
    }

    // Top 5 lines, most-frequent first (stable by name on ties).
    final lines = lineCounts.entries.toList()
      ..sort((a, b) {
        final c = b.value.compareTo(a.value);
        return c != 0 ? c : a.key.compareTo(b.key);
      });
    final topLines = <TopLine>[
      for (final e in lines.take(5)) TopLine(e.key, e.value),
    ];

    return TripStatsSummary(
      totalTrips: records.length,
      monthTrips: monthTrips,
      monthWokenOnTime: monthOnTime,
      lifetimeWokenOnTime: lifetimeOnTime,
      currentStreakDays: _currentStreak(dayNums, _dayNumber(asOf)),
      longestStreakDays: _longestStreak(dayNums),
      hourHistogram: hist,
      topLines: topLines,
      distinctStations: stations.length,
    );
  }

  /// DST-safe day ordinal: reinterpret the LOCAL calendar date as a UTC midnight
  /// so consecutive dates are exactly 86_400_000 ms apart (no 23/25h drift).
  static int _dayNumber(DateTime local) =>
      DateTime.utc(local.year, local.month, local.day).millisecondsSinceEpoch ~/
      86400000;

  static int _currentStreak(Set<int> days, int today) {
    if (days.isEmpty) return 0;
    // Anchor at today, or yesterday if there is no trip today (a run in
    // progress but not yet extended to the current day still counts as current).
    var cursor = days.contains(today)
        ? today
        : (days.contains(today - 1) ? today - 1 : null);
    if (cursor == null) return 0;
    var streak = 0;
    while (days.contains(cursor)) {
      streak++;
      cursor = cursor! - 1;
    }
    return streak;
  }

  static int _longestStreak(Set<int> days) {
    if (days.isEmpty) return 0;
    final sorted = days.toList()..sort();
    var longest = 1;
    var run = 1;
    for (var i = 1; i < sorted.length; i++) {
      if (sorted[i] == sorted[i - 1] + 1) {
        run++;
        if (run > longest) longest = run;
      } else {
        run = 1;
      }
    }
    return longest;
  }
}
