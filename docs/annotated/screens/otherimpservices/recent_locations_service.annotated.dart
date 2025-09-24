// docs/annotated/screens/otherimpservices/recent_locations_service.annotated.dart
// Annotated copy of lib/screens/otherimpservices/recent_locations_service.dart
// Purpose: Explain Hive-backed storage for recent destinations with corruption handling.

import 'package:hive_flutter/hive_flutter.dart'; // Lightweight local KV database.
import 'dart:developer' as dev; // Logging.

class RecentLocationsService {
  static const String boxName = 'recent_locations'; // Hive box identifier.
  static Box? _box; // Lazily opened Hive box instance.

  // Ensures the Hive box is open and usable; recreates it if corrupted.
  static Future<void> _ensureBoxIsOpen() async {
    if (_box != null && _box!.isOpen) {
      return; // Fast path when already open.
    }

    try {
      _box = await Hive.openBox(boxName); // Open (or create) the box.
      dev.log("Hive box '$boxName' opened successfully.", name: "RecentLocationsService");
    } catch (e) {
      dev.log("Error opening Hive box: $e. This may indicate corruption.", name: "RecentLocationsService");

      // Attempt to recover from corruption by deleting and recreating the box.
      try {
        await Hive.deleteBoxFromDisk(boxName);
        _box = await Hive.openBox(boxName);
        dev.log("Corrupted box deleted and recreated successfully.", name: "RecentLocationsService");
      } catch (recreateError) {
        dev.log("Failed to recreate box after corruption: $recreateError", name: "RecentLocationsService");
        rethrow; // Surface failure if recovery also fails.
      }
    }
  }

  // Read list of recent locations from storage; returns empty list on failure.
  static Future<List<Map<String, dynamic>>> getRecentLocations() async {
    try {
      await _ensureBoxIsOpen();
      final storedData = _box!.get('locations'); // Raw stored value.

      if (storedData is List) {
        // Normalize types to List<Map<String, dynamic>> safely.
        final List<Map<String, dynamic>> result = List<Map<String, dynamic>>.from(
          storedData.whereType<Map>().map((item) => Map<String, dynamic>.from(item)),
        );
        dev.log("Retrieved ${result.length} recent locations.", name: "RecentLocationsService");
        return result;
      }

      return []; // No data stored yet.
    } catch (e) {
      dev.log("Error getting recent locations: $e", name: "RecentLocationsService");
      return [];
    }
  }

  // Persist recent locations list to storage; flush for durability.
  static Future<void> saveRecentLocations(List<Map<String, dynamic>> locations) async {
    try {
      await _ensureBoxIsOpen();
      await _box!.put('locations', locations);
      await _box!.flush(); // Ensure data hits disk.
      dev.log("Saved ${locations.length} recent locations to storage.", name: "RecentLocationsService");
    } catch (e) {
      dev.log("Error saving recent locations: $e", name: "RecentLocationsService");
    }
  }
}

// Post-block summary:
// - Uses a single Hive box 'recent_locations' to store a list of maps.
// - On open failure, deletes and recreates the box to recover from corruption.
// - Normalizes list contents to the expected map type on read.
// - Flushes writes to ensure durability immediately.

// End-of-file summary:
// Simple, resilient persistence for the HomeScreen recents feature. This design
// encapsulates Hive interactions and recovery logic, keeping UI code clean and
// making storage failures non-fatal by falling back to empty lists.
