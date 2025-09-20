import 'package:hive_flutter/hive_flutter.dart';
import 'dart:developer' as dev;

class RecentLocationsService {
  static const String boxName = 'recent_locations';
  static Box? _box;

  // This is the gatekeeper function. It ensures the box is open and ready.
  // It's the most critical part of the fix.
  static Future<void> _ensureBoxIsOpen() async {
    // If the box is already open and valid, do nothing.
    if (_box != null && _box!.isOpen) {
      return;
    }

    try {
      _box = await Hive.openBox(boxName);
      dev.log("Hive box '$boxName' opened successfully.", name: "RecentLocationsService");
    } catch (e) {
      dev.log("Error opening Hive box: $e. This may indicate corruption.", name: "RecentLocationsService");
      
      // If opening fails, the file is likely corrupt. Delete and recreate it.
      try {
        await Hive.deleteBoxFromDisk(boxName);
        _box = await Hive.openBox(boxName);
        dev.log("Corrupted box deleted and recreated successfully.", name: "RecentLocationsService");
      } catch (recreateError) {
        dev.log("Failed to recreate box after corruption: $recreateError", name: "RecentLocationsService");
        rethrow; // Propagate the error if recreation also fails.
      }
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
      await _box!.put('locations', locations);
      // `flush()` ensures the data is written to disk immediately.
      await _box!.flush();
      dev.log("Saved ${locations.length} recent locations to storage.", name: "RecentLocationsService");
    } catch (e) {
      dev.log("Error saving recent locations: $e", name: "RecentLocationsService");
    }
  }
}