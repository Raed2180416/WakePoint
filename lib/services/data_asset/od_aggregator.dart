// lib/services/data_asset/od_aggregator.dart
//
// GeoWake — on-device aggregator (DATA_SURFACE_SPEC §2.5).
//
// Holds ONLY COUNTS. Two self-healing Hive boxes:
//   • gw_od_aggregate_v1     : String cellKey  -> int O-D count
//   • gw_station_arrival_v1  : String arrivalKey -> int catchment count
// plus an append-only erasure log (gw_od_erasure_log_v1) written on withdrawal
// for DPDP s.8(7)/s.12 auditability.
//
// NO coordinate is ever stored (the aggregator only ever sees pre-snapped
// [TripEndpoint]s). Every method is wrapped and fail-open — mirrors
// TelemetryService._emit: a bad box must never throw into the trip-completion
// path or the alarm spine.

import 'dart:convert';
import 'dart:developer' as dev;

import 'package:hive_flutter/hive_flutter.dart';

import 'contribution_cap.dart';
import 'od_cell.dart';
import 'station_binner.dart';

class OdAggregator {
  static const String odBoxName = 'gw_od_aggregate_v1';
  static const String arrivalBoxName = 'gw_station_arrival_v1';
  static const String erasureLogBoxName = 'gw_od_erasure_log_v1';

  final ContributionCap _cap;

  final Box<int>? _injectedOdBox;
  final Box<int>? _injectedArrivalBox;
  final Box<String>? _injectedErasureBox;

  Box<int>? _odBox;
  Box<int>? _arrivalBox;
  Box<String>? _erasureBox;

  OdAggregator({
    ContributionCap? cap,
    Box<int>? odBox,
    Box<int>? arrivalBox,
    Box<String>? erasureBox,
  })  : _cap = cap ?? ContributionCap(),
        _injectedOdBox = odBox,
        _injectedArrivalBox = arrivalBox,
        _injectedErasureBox = erasureBox;

  Future<Box<int>> _ensureOdBox() async =>
      _injectedOdBox ?? (_odBox ??= await _openIntBox(odBoxName));

  Future<Box<int>> _ensureArrivalBox() async =>
      _injectedArrivalBox ??
      (_arrivalBox ??= await _openIntBox(arrivalBoxName));

  Future<Box<String>> _ensureErasureBox() async =>
      _injectedErasureBox ??
      (_erasureBox ??= await _openStringBox(erasureLogBoxName));

  Future<Box<int>> _openIntBox(String name) async {
    try {
      return await Hive.openBox<int>(name);
    } catch (e) {
      dev.log('int box $name open failed: $e; recreating', name: 'OdAggregator');
      await Hive.deleteBoxFromDisk(name);
      return await Hive.openBox<int>(name);
    }
  }

  Future<Box<String>> _openStringBox(String name) async {
    try {
      return await Hive.openBox<String>(name);
    } catch (e) {
      dev.log('string box $name open failed: $e; recreating',
          name: 'OdAggregator');
      await Hive.deleteBoxFromDisk(name);
      return await Hive.openBox<String>(name);
    }
  }

  /// Records one completed trip as counts (never coordinates). Enforces the
  /// contribution cap (sensitivity bound) BEFORE incrementing. Fail-open: the
  /// whole body is guarded and never throws.
  Future<void> recordTrip({
    required TripEndpoint origin,
    required TripEndpoint destination,
    required String localDate,
  }) async {
    try {
      // Self-trip / degenerate O-D (same station both ends) carries no flow.
      if (origin.stationId == destination.stationId) return;

      final key = OdCellKey(
        originStationId: origin.stationId,
        destStationId: destination.stationId,
        hourBin: origin.hourBin,
        dayType: origin.dayType,
      );

      final reserved = await _cap.tryReserve(key, localDate: localDate);
      if (!reserved) return; // cap hit ⇒ this trip does not contribute.

      final odBox = await _ensureOdBox();
      final keyStr = key.toKeyString();
      await odBox.put(keyStr, (odBox.get(keyStr) ?? 0) + 1);

      // Catchment (station arrival) count — keyed on the DESTINATION endpoint.
      final arrivalBox = await _ensureArrivalBox();
      final arrivalCell = StationArrivalCell(
        stationId: destination.stationId,
        hourBin: destination.hourBin,
        dayType: destination.dayType,
        count: 0,
      );
      final aKey = arrivalCell.toKeyString();
      await arrivalBox.put(aKey, (arrivalBox.get(aKey) ?? 0) + 1);
    } catch (e) {
      dev.log('recordTrip failed (swallowed): $e', name: 'OdAggregator');
    }
  }

  /// The current on-device O-D snapshot. On a single device `contributingUsers`
  /// is 1 for every cell (real cross-device counts require the merge backend).
  /// Never throws — returns [] on error.
  Future<List<OdCell>> snapshot() async {
    try {
      final odBox = await _ensureOdBox();
      final cells = <OdCell>[];
      for (final entry in odBox.toMap().entries) {
        final k = entry.key;
        final v = entry.value;
        if (k is! String) continue;
        final key = OdCellKey.tryParse(k);
        if (key == null) continue;
        cells.add(OdCell(key: key, count: v, contributingUsers: 1));
      }
      return cells;
    } catch (e) {
      dev.log('snapshot failed: $e', name: 'OdAggregator');
      return const [];
    }
  }

  /// The current on-device catchment snapshot. Never throws.
  Future<List<StationArrivalCell>> catchmentSnapshot() async {
    try {
      final box = await _ensureArrivalBox();
      final out = <StationArrivalCell>[];
      for (final entry in box.toMap().entries) {
        final k = entry.key;
        final v = entry.value;
        if (k is! String) continue;
        final parts = k.split('|');
        if (parts.length != 3) continue;
        final hour = int.tryParse(parts[1]);
        if (hour == null) continue;
        final day = DayType.values.where((d) => d.name == parts[2]);
        if (day.isEmpty) continue;
        out.add(StationArrivalCell(
          stationId: parts[0],
          hourBin: hour,
          dayType: day.first,
          count: v,
        ));
      }
      return out;
    } catch (e) {
      dev.log('catchmentSnapshot failed: $e', name: 'OdAggregator');
      return const [];
    }
  }

  /// Erases ALL aggregate state (both count boxes + the contribution cap) and
  /// appends an auditable erasure record. Called on consent withdrawal
  /// (DPDP s.8(7)/s.12). Never throws.
  Future<void> wipeAndLogErasure({required int atMs, String reason = 'withdrawal'}) async {
    try {
      final odBox = await _ensureOdBox();
      await odBox.clear();
    } catch (e) {
      dev.log('od box wipe failed: $e', name: 'OdAggregator');
    }
    try {
      final arrivalBox = await _ensureArrivalBox();
      await arrivalBox.clear();
    } catch (e) {
      dev.log('arrival box wipe failed: $e', name: 'OdAggregator');
    }
    try {
      await _cap.clear();
    } catch (e) {
      dev.log('cap clear failed: $e', name: 'OdAggregator');
    }
    try {
      final log = await _ensureErasureBox();
      await log.add(jsonEncode({
        'event': 'erasure',
        'reason': reason,
        'atMs': atMs,
        'schema': 'od-erasure-v1',
      }));
    } catch (e) {
      dev.log('erasure log append failed: $e', name: 'OdAggregator');
    }
  }

  /// Number of erasure records on file (for audit/debug/tests). 0 on error.
  Future<int> erasureLogLength() async {
    try {
      final log = await _ensureErasureBox();
      return log.length;
    } catch (_) {
      return 0;
    }
  }
}
