// lib/services/data_asset/contribution_cap.dart
//
// GeoWake — per-user contribution cap (DATA_SURFACE_SPEC §2.4).
//
// Bounds the DP L1 sensitivity: each local day, a user may contribute AT MOST
// [kPerUserMaxCountPerCellPerDay] (=1, an indicator) to a given cell, and AT
// MOST [kPerUserMaxCellsPerDay] (=4) DISTINCT cells total. That makes per-user
// L1 sensitivity provably ≤ 4 for the daily DP budget.
//
// Storage: one self-healing `Box<String>` (`gw_od_contribcap_v1`) holding a JSON
// map { localDate -> [cellKeyString, ...] }. Old days are pruned. Fail-open —
// every method swallows errors and degrades safely (a failed reserve just means
// the trip isn't counted, never a crash).

import 'dart:convert';
import 'dart:developer' as dev;

import 'package:hive_flutter/hive_flutter.dart';

import 'data_asset_config.dart';
import 'od_cell.dart';

class ContributionCap {
  static const String boxName = 'gw_od_contribcap_v1';
  static const String _key = 'days';

  final Box<String>? _injectedBox;
  Box<String>? _box;
  Future<void>? _opening;

  ContributionCap({Box<String>? box}) : _injectedBox = box;

  Future<Box<String>> _ensureBox() async {
    if (_injectedBox != null) return _injectedBox;
    if (_box != null && _box!.isOpen) return _box!;
    if (_opening != null) {
      await _opening;
      return _box!;
    }
    _opening = () async {
      try {
        _box = await Hive.openBox<String>(boxName);
      } catch (e) {
        dev.log('contribcap box open failed: $e; recreating',
            name: 'ContributionCap');
        await Hive.deleteBoxFromDisk(boxName);
        _box = await Hive.openBox<String>(boxName);
      }
    }();
    try {
      await _opening;
    } finally {
      _opening = null;
    }
    return _box!;
  }

  Map<String, List<String>> _decode(Box<String> box) {
    try {
      final raw = box.get(_key);
      if (raw == null || raw.isEmpty) return {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final out = <String, List<String>>{};
      decoded.forEach((k, v) {
        if (k is String && v is List) {
          out[k] = v.whereType<String>().toList();
        }
      });
      return out;
    } catch (_) {
      return {};
    }
  }

  Future<void> _write(Box<String> box, Map<String, List<String>> days) async {
    try {
      await box.put(_key, jsonEncode(days));
    } catch (e) {
      dev.log('contribcap write failed: $e', name: 'ContributionCap');
    }
  }

  /// Attempts to reserve one contribution slot for [key] on [localDate]. Returns
  /// true iff (a) the cell has not already been counted today
  /// (kPerUserMaxCountPerCellPerDay = 1) AND (b) the user is still under
  /// [kPerUserMaxCellsPerDay] distinct cells today. Prunes non-current days.
  Future<bool> tryReserve(OdCellKey key, {required String localDate}) async {
    try {
      final box = await _ensureBox();
      final days = _decode(box);

      // Prune every day that isn't the current local date (per-day rollover).
      days.removeWhere((d, _) => d != localDate);

      final today = days.putIfAbsent(localDate, () => <String>[]);
      final keyStr = key.toKeyString();

      if (today.contains(keyStr)) return false; // per-cell cap (=1) hit.
      if (today.length >= kPerUserMaxCellsPerDay) return false; // 4-cell cap hit.

      today.add(keyStr);
      await _write(box, days);
      return true;
    } catch (e) {
      dev.log('tryReserve failed: $e', name: 'ContributionCap');
      return false; // fail-safe: don't count on error.
    }
  }

  /// Clears all bookkeeping (called on consent withdrawal). Never throws.
  Future<void> clear() async {
    try {
      final box = await _ensureBox();
      await box.delete(_key);
    } catch (e) {
      dev.log('contribcap clear failed: $e', name: 'ContributionCap');
    }
  }
}
