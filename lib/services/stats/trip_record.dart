// lib/services/stats/trip_record.dart
//
// One immutable, PII-free record of a completed GeoWake trip. Written
// fire-and-forget off the alarm path (see TripStatsService) so upgraders keep
// their history and the free shareable stat card / headline count work for
// everyone.
//
// PRIVACY INVARIANT: a TripRecord carries only coarse NAMES and time buckets —
// never latitude/longitude, never a device/user id. `validate()` reuses the
// shared `PiiGuard` patterns and is asserted at construction of every record
// that enters the ledger, so a coordinate-looking station/line/city string is
// rejected here rather than persisted or (via the share image) leaked.
//
// Pure Dart (no Flutter / no I/O) — unit-testable in isolation.
library;

import 'package:geowake2/services/privacy/pii_guard.dart';

/// A single completed-trip datum. All fields are coarse and PII-free.
class TripRecord {
  /// Wall-clock completion time (epoch ms). The only timestamp stored.
  final int completedAtMs;

  /// Coarse destination station / zone NAME (never a coordinate). Nullable —
  /// the alarm path may fire without a resolved station name.
  final String? destStation;

  /// Coarse transit line name (e.g. "Purple Line"). Nullable.
  final String? line;

  /// Coarse city/zone label. Nullable.
  final String? city;

  /// Alarm mode bucket: 'distance' | 'time' | 'stops' | 'unknown'.
  final String mode;

  /// `AlarmOutcome.name` at fire time (e.g. 'onTime'). Free-form but coarse.
  final String outcome;

  /// Local hour-of-day bucket [0..23], derived from [completedAtMs].
  final int hourOfDay;

  /// Local ISO weekday [1..7] (Mon=1), derived from [completedAtMs].
  final int weekday;

  /// Whether GeoWake woke the rider in time (the growth-loop headline metric).
  final bool wokenOnTime;

  const TripRecord({
    required this.completedAtMs,
    required this.mode,
    required this.outcome,
    required this.hourOfDay,
    required this.weekday,
    required this.wokenOnTime,
    this.destStation,
    this.line,
    this.city,
  });

  /// Build a record for "now" (or an injected [completedAtMs]), deriving the
  /// hour/weekday buckets and — when not given — [wokenOnTime] from [outcome].
  ///
  /// A trip is considered woken-on-time unless the outcome is explicitly a
  /// late/missed wake, so the free headline count is conservative-positive.
  factory TripRecord.build({
    required String mode,
    required String outcome,
    int? completedAtMs,
    String? destStation,
    String? line,
    String? city,
    bool? wokenOnTime,
  }) {
    final ms = completedAtMs ?? DateTime.now().millisecondsSinceEpoch;
    final local = DateTime.fromMillisecondsSinceEpoch(ms);
    final o = outcome.trim().isEmpty ? 'unknown' : outcome.trim();
    return TripRecord(
      completedAtMs: ms,
      mode: mode.trim().isEmpty ? 'unknown' : mode.trim(),
      outcome: o,
      hourOfDay: local.hour,
      weekday: local.weekday,
      wokenOnTime: wokenOnTime ?? (o != 'late' && o != 'missed'),
      destStation: _clean(destStation),
      line: _clean(line),
      city: _clean(city),
    );
  }

  static String? _clean(String? v) {
    if (v == null) return null;
    final t = v.trim();
    return t.isEmpty ? null : t;
  }

  /// Assert the PII-free invariant. Throws [PiiViolation] if any name field
  /// carries coordinate/PII-looking content. Called before a record is
  /// persisted or rendered into the share image.
  void validate() {
    PiiGuard.assertCleanNullable('destStation', destStation);
    PiiGuard.assertCleanNullable('line', line);
    PiiGuard.assertCleanNullable('city', city);
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'completedAtMs': completedAtMs,
        'destStation': destStation,
        'line': line,
        'city': city,
        'mode': mode,
        'outcome': outcome,
        'hourOfDay': hourOfDay,
        'weekday': weekday,
        'wokenOnTime': wokenOnTime,
      };

  /// Parse a persisted map. Returns null on any malformed row (fail-safe: a bad
  /// row is skipped, never crashes the ledger read).
  static TripRecord? fromJson(Map<dynamic, dynamic> m) {
    try {
      final ms = (m['completedAtMs'] as num?)?.toInt();
      if (ms == null) return null;
      final local = DateTime.fromMillisecondsSinceEpoch(ms);
      return TripRecord(
        completedAtMs: ms,
        destStation: m['destStation'] as String?,
        line: m['line'] as String?,
        city: m['city'] as String?,
        mode: (m['mode'] as String?) ?? 'unknown',
        outcome: (m['outcome'] as String?) ?? 'unknown',
        hourOfDay: (m['hourOfDay'] as num?)?.toInt() ?? local.hour,
        weekday: (m['weekday'] as num?)?.toInt() ?? local.weekday,
        wokenOnTime: m['wokenOnTime'] == true,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  String toString() =>
      'TripRecord(at: $completedAtMs, mode: $mode, outcome: $outcome, '
      'onTime: $wokenOnTime)';
}
