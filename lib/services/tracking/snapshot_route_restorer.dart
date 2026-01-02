import 'dart:developer' as dev;

import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'package:geowake2/services/tracking_state_store.dart';

typedef RegisterRouteFromDirections =
    Future<void> Function({
      required Map<String, dynamic> directions,
      required LatLng origin,
      required LatLng destination,
      required bool transitMode,
      String? destinationName,
    });

class SnapshotRouteRestorer {
  static Future<void> restoreFromStoreIfActiveAndNotPaused({
    required Future<bool> Function() isActive,
    required Future<bool> Function() isPaused,
    required Future<TrackingSnapshot?> Function() loadSnapshot,
    required RegisterRouteFromDirections registerRouteFromDirections,
    String logName = 'TrackingService',
    String successLogMessage =
        'Background: Restored route from snapshot directions',
    String failureLogPrefix =
        'Background: Failed to restore route from snapshot:',
  }) async {
    try {
      final active = await isActive();
      final paused = await isPaused();
      if (!active || paused) return;

      final snapshot = await loadSnapshot();
      await restoreFromSnapshotIfDirectionsPresent(
        snapshot: snapshot,
        registerRouteFromDirections: registerRouteFromDirections,
      );

      if (snapshot?.directions != null) {
        dev.log(successLogMessage, name: logName);
      }
    } catch (e) {
      dev.log('$failureLogPrefix $e', name: logName);
    }
  }

  static Future<void> restoreFromSnapshotIfDirectionsPresent({
    required TrackingSnapshot? snapshot,
    required RegisterRouteFromDirections registerRouteFromDirections,
    LatLng? destinationOverride,
    String? destinationNameOverride,
  }) async {
    if (snapshot?.directions == null) return;

    await registerRouteFromDirections(
      directions: snapshot!.directions!,
      origin: LatLng(snapshot.userLat, snapshot.userLng),
      destination:
          destinationOverride ??
          LatLng(snapshot.destinationLat, snapshot.destinationLng),
      transitMode: snapshot.metroMode,
      destinationName: destinationNameOverride ?? snapshot.destinationName,
    );
  }
}
