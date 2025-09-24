import 'package:hive_flutter/hive_flutter.dart';
import 'dart:developer' as dev;

class RecentLocationsService {
  static const String boxName = 'recent_locations';
  static Box? _box;
  static Future<void>? _opening;
  static const int _maxItems = 15;

  // This is the gatekeeper function. It ensures the box is open and ready.
  // It's the most critical part of the fix.
  static Future<void> _ensureBoxIsOpen() async {
    if (_box != null && _box!.isOpen) return;
    if (_opening != null) return _opening; // Another caller is opening
    _opening = () async {
      try {
        _box = await Hive.openBox(boxName);
        dev.log("Hive box '$boxName' opened successfully.", name: "RecentLocationsService");
      } catch (e) {
        dev.log("Error opening Hive box: $e. This may indicate corruption.", name: "RecentLocationsService");
        try {
          await Hive.deleteBoxFromDisk(boxName);
          _box = await Hive.openBox(boxName);
          dev.log("Corrupted box deleted and recreated successfully.", name: "RecentLocationsService");
        } catch (recreateError) {
          dev.log("Failed to recreate box after corruption: $recreateError", name: "RecentLocationsService");
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

  // Retrieve stored recent locations.
  static Future<List<Map<String, dynamic>>> getRecentLocations() async {
    try {
      await _ensureBoxIsOpen();
      final storedData = _box!.get('locations');
      
      if (storedData is List) {
        // Ensure all items in the list are of the correct type.
        final List<Map<String, dynamic>> result = List<Map<String, dynamic>>.from(
          storedData.whereType<Map>().map((item) => Map<String, dynamic>.from(item))
        );
        dev.log("Retrieved ${result.length} recent locations.", name: "RecentLocationsService");
        return result;
      }
      
      // If data is null or not a list, return an empty list.
      return [];
    } catch (e) {
      dev.log("Error getting recent locations: $e", name: "RecentLocationsService");
      return [];
    }
  }

  // Persist the list of recent locations.
  static Future<void> saveRecentLocations(List<Map<String, dynamic>> locations) async {
    try {
      await _ensureBoxIsOpen();
      // Normalize, dedupe, and cap size
      final seen = <String>{};
      List<Map<String, dynamic>> normalized = locations
          .map((m) => Map<String, dynamic>.from(m))
          .where((m) => m.isNotEmpty)
          .toList();
      List<Map<String, dynamic>> deduped = [];
      for (final m in normalized) {
        final key = (m['placeId'] ?? m['place_id'] ?? '${m['lat']},${m['lng']}').toString();
        if (seen.add(key)) deduped.add(m);
      }
      if (deduped.length > _maxItems) {
        deduped = deduped.sublist(0, _maxItems);
      }

      await _box!.put('locations', deduped);
      dev.log("Saved ${deduped.length} recent locations to storage.", name: "RecentLocationsService");
    } catch (e) {
      dev.log("Error saving recent locations: $e", name: "RecentLocationsService");
    }
  }
}