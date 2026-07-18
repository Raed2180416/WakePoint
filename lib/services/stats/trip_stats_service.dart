// lib/services/stats/trip_stats_service.dart
//
// LOCAL-ONLY trip ledger for GeoWake. One PII-free [TripRecord] per completed
// trip, capped at [_ringCap]. Recording is UNCONDITIONAL and always-free — the
// growth loop (shareable stat card + headline count) depends on everyone,
// including free users, accumulating history.
//
// THIS IS NOT THE DATA_STRATEGY PIPELINE. Records never leave the device except
// via a user-initiated share IMAGE (see stat_card_exporter.dart). There is no
// sink / http import in this file, by design.
//
// ── SINGLE-WRITER INVARIANT (the load-bearing correctness property) ─────────
// The alarm most often fires in the BACKGROUND isolate (app swiped away), where
// `Hive.initFlutter()` has NOT run and opening the box would either throw ("not
// initialized") — systematically undercounting to zero — or, if "fixed" by
// initialising Hive there too, open the same box from two isolates and corrupt
// it (Hive is not multi-isolate-safe).
//
// So: the Hive box is opened and written ONLY from the UI isolate. A record
// produced in the background isolate is appended to a small append-only pending
// file (mirroring pending_ack_manager's file-handoff idea); the UI isolate
// drains that file into the box on the next foreground/resume. `recordTrip` is
// fail-safe and NEVER throws into the alarm path.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:io';

import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';

import 'package:geowake2/services/stats/trip_record.dart';
import 'package:geowake2/services/stats/trip_stats_summary.dart';

class TripStatsService {
  TripStatsService._();
  static final TripStatsService instance = TripStatsService._();

  static const String boxName = 'geowake_trip_stats_v1';
  static const String _recordsKey = 'records';
  static const String _pendingFileName = 'gw_trip_stats_pending.log';

  /// Ring capacity — oldest records beyond this are dropped on write.
  static const int _ringCap = 2000;

  /// Test seam: override the directory used for the pending file so unit tests
  /// don't need the path_provider plugin. Ignored in production.
  static String? debugPendingDirPathOverride;

  Box? _box;
  Future<void>? _opening;
  String? _cachedPendingDirPath;

  // ── Write path ─────────────────────────────────────────────────────────────

  /// Record a completed trip. NEVER throws (double-swallowed at the call site
  /// too). When [fromBackgroundIsolate] is true the record is appended to the
  /// pending file for the UI isolate to drain; otherwise it is written inline
  /// (and any pending file is drained first).
  ///
  /// Pass `fromBackgroundIsolate: context.isBackgroundIsolate` from the alarm
  /// controller so the isolate that actually opens Hive is always the UI one.
  Future<void> recordTrip(
    TripRecord record, {
    bool fromBackgroundIsolate = false,
  }) async {
    try {
      // Reject anything that looks like a coordinate/PII leak before it lands.
      record.validate();
    } catch (e) {
      dev.log('recordTrip rejected (PII guard): $e', name: 'TripStatsService');
      return;
    }
    try {
      if (fromBackgroundIsolate) {
        await _appendPending(record);
      } else {
        await _drainPendingIntoBox();
        await _appendToBox(record);
      }
    } catch (e) {
      dev.log('recordTrip failed (swallowed): $e', name: 'TripStatsService');
    }
  }

  /// Drain any pending background-isolate records into the box. Call from the UI
  /// isolate on foreground/resume (piggyback main.dart's lifecycle flush).
  Future<void> drainPending() async {
    try {
      await _drainPendingIntoBox();
    } catch (e) {
      dev.log('drainPending failed (swallowed): $e', name: 'TripStatsService');
    }
  }

  // ── Read path (UI isolate only) ─────────────────────────────────────────────

  /// All records, oldest-first. Drains the pending file first so freshly
  /// background-recorded trips are included. Returns [] on any failure.
  Future<List<TripRecord>> allTrips() async {
    try {
      await _drainPendingIntoBox();
      return _readRecords();
    } catch (e) {
      dev.log('allTrips failed: $e', name: 'TripStatsService');
      return const <TripRecord>[];
    }
  }

  /// The rich rollup. `now` injectable for tests.
  Future<TripStatsSummary> summary({DateTime? now}) async {
    final trips = await allTrips();
    return TripStatsSummary.compute(trips, now: now);
  }

  /// Lifetime count of on-time wakes — the all-time headline number.
  Future<int> lifetimeWokenOnTime() async {
    final trips = await allTrips();
    var n = 0;
    for (final t in trips) {
      if (t.wokenOnTime) n++;
    }
    return n;
  }

  /// This-calendar-month on-time wakes — the default share-card headline.
  Future<int> monthWokenOnTime({DateTime? now}) async {
    return (await summary(now: now)).monthWokenOnTime;
  }

  /// Wipe the ledger (behind a confirm in the UI). Also clears pending.
  Future<void> clear() async {
    try {
      await _ensureBox();
      await _box!.put(_recordsKey, const <Map<String, dynamic>>[]);
    } catch (e) {
      dev.log('clear box failed: $e', name: 'TripStatsService');
    }
    try {
      final f = await _pendingFile();
      if (await f.exists()) await f.delete();
    } catch (_) {/* best effort */}
  }

  // ── Box internals ───────────────────────────────────────────────────────────

  Future<void> _ensureBox() async {
    if (_box != null && _box!.isOpen) return;
    if (_opening != null) return _opening;
    _opening = () async {
      try {
        _box = await Hive.openBox(boxName);
      } catch (e) {
        // Self-healing: a corrupt box is deleted and recreated empty rather than
        // permanently breaking recording (mirrors RecentLocationsService).
        dev.log('box open failed, recreating: $e', name: 'TripStatsService');
        try {
          await Hive.deleteBoxFromDisk(boxName);
          _box = await Hive.openBox(boxName);
        } catch (e2) {
          dev.log('box recreate failed: $e2', name: 'TripStatsService');
          rethrow;
        }
      }
    }();
    try {
      await _opening;
    } finally {
      _opening = null;
    }
  }

  List<TripRecord> _readRecords() {
    final raw = _box?.get(_recordsKey);
    if (raw is! List) return const <TripRecord>[];
    final out = <TripRecord>[];
    for (final item in raw) {
      if (item is Map) {
        final r = TripRecord.fromJson(item);
        if (r != null) out.add(r);
      }
    }
    return out;
  }

  Future<void> _appendToBox(TripRecord record) async {
    await _ensureBox();
    final raw = _box!.get(_recordsKey);
    final list = <Map<String, dynamic>>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is Map) list.add(Map<String, dynamic>.from(item));
      }
    }
    list.add(record.toJson());
    // Keep only the newest [_ringCap] records.
    final capped = list.length > _ringCap
        ? list.sublist(list.length - _ringCap)
        : list;
    await _box!.put(_recordsKey, capped);
  }

  // ── Pending-file bridge (background isolate → UI isolate) ───────────────────

  Future<String> _pendingDirPath() async {
    final override = debugPendingDirPathOverride;
    if (override != null) return override;
    if (_cachedPendingDirPath != null) return _cachedPendingDirPath!;
    final dir = await getApplicationSupportDirectory();
    _cachedPendingDirPath = dir.path;
    return dir.path;
  }

  Future<File> _pendingFile() async {
    final dirPath = await _pendingDirPath();
    return File('$dirPath${Platform.pathSeparator}$_pendingFileName');
  }

  /// Append one record as a single JSON line. Safe to call from the background
  /// isolate (no Hive, just a file append).
  Future<void> _appendPending(TripRecord record) async {
    final f = await _pendingFile();
    final line = '${jsonEncode(record.toJson())}\n';
    await f.writeAsString(line, mode: FileMode.append, flush: true);
  }

  /// Move the pending file aside (atomic rename so concurrent appends land in a
  /// fresh file), parse its lines, and fold them into the box. Runs UI-side.
  Future<void> _drainPendingIntoBox() async {
    final f = await _pendingFile();
    if (!await f.exists()) return;

    // Rename to a unique temp so appends from the background isolate that race
    // this drain go to a new pending file and aren't lost.
    File temp;
    try {
      final stamp = DateTime.now().microsecondsSinceEpoch;
      temp = await f.rename('${f.path}.$stamp.draining');
    } catch (_) {
      // Rename can fail if the file vanished between exists() and rename(); a
      // concurrent drain already took it — nothing to do.
      return;
    }

    List<String> lines;
    try {
      lines = await temp.readAsLines();
    } catch (e) {
      dev.log('pending read failed: $e', name: 'TripStatsService');
      try {
        await temp.delete();
      } catch (_) {}
      return;
    }

    final records = <TripRecord>[];
    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      try {
        final decoded = jsonDecode(line);
        if (decoded is Map) {
          final r = TripRecord.fromJson(decoded);
          if (r != null) records.add(r);
        }
      } catch (_) {/* skip a corrupt line, keep the rest */}
    }

    if (records.isNotEmpty) {
      await _ensureBox();
      final raw = _box!.get(_recordsKey);
      final list = <Map<String, dynamic>>[];
      if (raw is List) {
        for (final item in raw) {
          if (item is Map) list.add(Map<String, dynamic>.from(item));
        }
      }
      for (final r in records) {
        list.add(r.toJson());
      }
      final capped = list.length > _ringCap
          ? list.sublist(list.length - _ringCap)
          : list;
      await _box!.put(_recordsKey, capped);
    }

    try {
      await temp.delete();
    } catch (_) {/* best effort */}
  }

  /// Test seam — reset in-memory handles between tests.
  Future<void> resetForTest() async {
    try {
      if (_box != null && _box!.isOpen) await _box!.close();
    } catch (_) {}
    _box = null;
    _opening = null;
    _cachedPendingDirPath = null;
  }
}
