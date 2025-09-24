// Annotated copy of lib/services/direction_service.dart
// Purpose: Explain tiered fetching via ApiClient, L2 caching, and segmented polyline building.

import 'package:flutter/material.dart'; // Colors and PatternItem for map polylines
import 'package:google_maps_flutter/google_maps_flutter.dart'; // LatLng and Polyline
import 'package:geolocator/geolocator.dart'; // Distance calculations
import 'package:geowake2/services/polyline_decoder.dart'; // Decode encoded polylines
import 'package:geowake2/services/polyline_simplifier.dart'; // Simplify and compress polylines
import 'package:geowake2/services/api_client.dart'; // Secure server API
import 'package:geowake2/services/route_cache.dart'; // Persistent route cache
import 'dart:developer' as dev; // Logging

class DirectionService { // Fetches directions and produces display polylines
  final ApiClient _apiClient = ApiClient.instance; // Shared API client
  Map<String, dynamic>? _cachedDirections; // In-memory cache
  DateTime? _lastFetchTime; // Last fetch timestamp
  // P1: In-memory cache for decode+simplify keyed by md5 of (polyline + tolerance)
  // This prevents repeated decode/simplify for identical step polylines across builds.
  // Implementation lives in lib/services/direction_service.dart as _polylineSimplifyCache.

  // Tiered intervals for updating directions.
  final Duration farInterval = const Duration(minutes: 15);
  final Duration midInterval = const Duration(minutes: 7);
  final Duration nearInterval = const Duration(minutes: 3);

  DirectionService(); // Default ctor

  /// Fetches directions using a tiered strategy through your secure API.
  Future<Map<String, dynamic>> getDirections(
    double startLat,
    double startLng,
    double endLat,
    double endLng, {
    required bool isDistanceMode, // Distance threshold used to set update cadence
    required double threshold, // Threshold value for distance-mode
    required bool transitMode, // If true, request transit routing
    bool forceRefresh = false, // Ignore caches
  }) async {
    // L2 persistent cache check (Hive)
    final origin = LatLng(startLat, startLng);
    final dest = LatLng(endLat, endLng);
    final mode = transitMode ? 'transit' : 'driving';
    if (!forceRefresh) {
      final cached = await RouteCache.get(
        origin: origin,
        destination: dest,
        mode: mode,
        transitVariant: transitMode ? 'rail' : null,
      );
      if (cached != null) {
        dev.log('Using RouteCache entry for $mode', name: 'DirectionService');
        _cachedDirections = cached.directions;
        _lastFetchTime = cached.timestamp;
      }
    }
    // Calculate the straight-line distance in meters.
    double straightDistance = Geolocator.distanceBetween(startLat, startLng, endLat, endLng);

    // Determine the update interval.
    Duration updateInterval;
    if (isDistanceMode) {
      double thresholdMeters = threshold * 1000;
      if (straightDistance > 5 * thresholdMeters) {
        updateInterval = farInterval; // Far: fetch less often
      } else if (straightDistance > 2 * thresholdMeters) {
        updateInterval = midInterval; // Mid range cadence
      } else {
        updateInterval = nearInterval; // Near destination: fetch more often
      }
    } else {
      updateInterval = nearInterval; // Time/stops mode: keep near cadence
    }

    // Return in-memory cached data if available and recent.
    if (!forceRefresh && _cachedDirections != null && _lastFetchTime != null) {
      final elapsed = DateTime.now().difference(_lastFetchTime!);
      if (elapsed < updateInterval) {
        return _cachedDirections!; // Fresh enough, use memory cache
      }
    }

    try {
      // REPLACE THE DIRECT HTTP CALL WITH API CLIENT
      final directions = await _apiClient.getDirections(
        origin: '$startLat,$startLng',
        destination: '$endLat,$endLng',
        mode: transitMode ? 'transit' : 'driving',
        transitMode: transitMode ? 'rail' : null,
      );

      if (directions['status'] != 'OK' || (directions['routes'] as List).isEmpty) {
        throw Exception("No feasible route found: ${directions['error_message'] ?? directions['status']}");
      }

  // --- Simplify & compress the overview polyline (with cached decode+simplify) ---
      String? simplifiedCompressed;
      if (directions['routes'] != null && directions['routes'].isNotEmpty) {
        final route = directions['routes'][0];
        if (route['overview_polyline'] != null && route['overview_polyline']['points'] != null) {
          final String encodedPolyline = route['overview_polyline']['points'] as String;
          // Decode + simplify with a small in-memory cache to avoid repeated work.
          // See _decodeAndSimplifyCached in the impl which uses md5(encoded + tol) as key.
          List<LatLng> simplifiedPoints = PolylineSimplifier.simplifyPolyline(decodePolyline(encodedPolyline), 10);
          // Compress the simplified polyline.
          String compressedPolyline = PolylineSimplifier.compressPolyline(simplifiedPoints);
          // Add the simplified compressed polyline to the response.
          route['simplified_polyline'] = compressedPolyline;
          simplifiedCompressed = compressedPolyline;
        }
      }

      _cachedDirections = directions;
      _lastFetchTime = DateTime.now();

      // Persist to RouteCache (L2)
      try {
        final key = RouteCache.makeKey(
          origin: origin,
          destination: dest,
          mode: mode,
          transitVariant: transitMode ? 'rail' : null,
        );
        await RouteCache.put(RouteCacheEntry(
          key: key,
          directions: directions,
          timestamp: _lastFetchTime!,
          origin: origin,
          destination: dest,
          mode: mode,
          simplifiedCompressedPolyline: simplifiedCompressed,
        ));
      } catch (e) {
        dev.log('Failed to persist route cache: $e', name: 'DirectionService');
      }
      return directions;

    } catch (e) {
      dev.log("Error fetching directions via API client: $e", name: "DirectionService");
      throw Exception("Failed to fetch directions: $e");
    }
  }

  // Rest of the class remains the same...
  List<Polyline> buildSegmentedPolylines(Map<String, dynamic> directions, bool transitMode) { // Build styled polylines
    List<Polyline> polylines = [];
    if (directions['routes'] == null || directions['routes'].isEmpty) return polylines;

  Map<String, Color> transitColorMap = {};
  // Only use green and purple for metro transit lines; deterministic assignment
  final List<Color> transitColors = [Colors.green, Colors.purple];
  int transitColorIndex = 0;

    for (var leg in directions['routes'][0]['legs']) {
      List<dynamic> steps = leg['steps'];
      if (steps.isEmpty) continue;

  List<LatLng> groupPoints = [];
  String currentGroupType;
  // non_transit subtype to distinguish DRIVING vs WALKING for styling
  String? currentNonTransitMode; // 'DRIVING' | 'WALKING' | null when transit
      String? currentTransitLine;

      // Initialize first step
      var firstStep = steps[0];
      String firstMode = firstStep['travel_mode'];
  bool isFirstTransitMetro = false;
  if (firstMode == 'TRANSIT' && transitMode) {
        if (firstStep.containsKey('transit_details') && firstStep['transit_details'] != null) {
          var transitDetails = firstStep['transit_details'];
          var vehicleType = transitDetails['line']['vehicle']['type'];
          isFirstTransitMetro = vehicleType == 'SUBWAY' || vehicleType == 'HEAVY_RAIL' || vehicleType == 'RAIL';
          if (isFirstTransitMetro) {
            currentGroupType = "transit";
            currentTransitLine = transitDetails['line']['short_name'] ?? transitDetails['line']['name'];
          } else {
            currentGroupType = "non_transit";
            currentTransitLine = null;
            currentNonTransitMode = firstMode;
          }
        } else {
          currentGroupType = "non_transit";
          currentTransitLine = null;
          currentNonTransitMode = firstMode;
        }
      } else {
        currentGroupType = "non_transit";
        currentTransitLine = null;
        currentNonTransitMode = firstMode;
      }
  // Decode, simplify, then add first step points. P1: actual impl uses cached helper _decodeAndSimplifyCached
  List<LatLng> rawPoints = decodePolyline(firstStep['polyline']['points']);
  List<LatLng> simplifiedPoints = PolylineSimplifier.simplifyPolyline(rawPoints, 10);
      groupPoints.addAll(simplifiedPoints);

      for (int i = 1; i < steps.length; i++) {
        var step = steps[i];
        String stepMode = step['travel_mode'];
  String stepGroupType = "non_transit";
        String? stepTransitLine;
  bool isStepTransitMetro = false;
  String? stepNonTransitMode; // track DRIVING vs WALKING

        if (stepMode == 'TRANSIT' && transitMode) {
          if (step.containsKey('transit_details') && step['transit_details'] != null) {
            var transitDetails = step['transit_details'];
            var vehicleType = transitDetails['line']['vehicle']['type'];
            isStepTransitMetro = vehicleType == 'SUBWAY' || vehicleType == 'HEAVY_RAIL' || vehicleType == 'RAIL';
            if (isStepTransitMetro) {
              stepGroupType = "transit";
              stepTransitLine = transitDetails['line']['short_name'] ?? transitDetails['line']['name'];
            } else {
                stepGroupType = "non_transit";
                stepTransitLine = null;
                stepNonTransitMode = stepMode; // could be BUS etc., but treat as non_transit
            }
          }
          } else {
            // Non-transit: remember the specific mode for styling (DRIVING/WALKING)
            stepNonTransitMode = stepMode;
        }

        bool sameGroup = false;
          if (currentGroupType == "non_transit" && stepGroupType == "non_transit") {
            // keep grouping only if same non-transit mode to allow different styling
            sameGroup = (currentNonTransitMode == stepNonTransitMode);
        } else if (currentGroupType == "transit" && stepGroupType == "transit") {
          sameGroup = (currentTransitLine == stepTransitLine);
        }

        if (sameGroup) {
          // P1: impl uses cached decode+simplify; annotated doc keeps the high-level flow.
          List<LatLng> rawStepPoints = decodePolyline(step['polyline']['points']);
          List<LatLng> simplifiedStepPoints = PolylineSimplifier.simplifyPolyline(rawStepPoints, 10);
          groupPoints.addAll(simplifiedStepPoints);
        } else {
          Color groupColor;
          if (currentGroupType == "non_transit") {
            groupColor = Colors.blue;
          } else {
            if (!transitColorMap.containsKey(currentTransitLine)) {
              transitColorMap[currentTransitLine!] = transitColors[transitColorIndex % transitColors.length];
              transitColorIndex++;
            }
            groupColor = transitColorMap[currentTransitLine]!;
          }

          // Determine walking dashed pattern; driving solid
          List<PatternItem>? pattern;
          if (currentGroupType == 'non_transit' && currentNonTransitMode == 'WALKING') {
            pattern = [PatternItem.dash(20), PatternItem.gap(12)];
          }

          polylines.add(Polyline(
            polylineId: PolylineId('group_${polylines.length}'),
            points: groupPoints,
            color: groupColor,
            width: 5,
            patterns: pattern ?? const <PatternItem>[],
            zIndex: currentGroupType == 'transit' ? 3 : 2,
          ));

          groupPoints = [];
          currentGroupType = stepGroupType;
          currentTransitLine = stepTransitLine;
          currentNonTransitMode = stepNonTransitMode;
          // P1: impl uses cached decode+simplify; annotated doc keeps the high-level flow.
          List<LatLng> rawStepPoints = decodePolyline(step['polyline']['points']);
          List<LatLng> simplifiedStepPoints = PolylineSimplifier.simplifyPolyline(rawStepPoints, 10);
          groupPoints.addAll(simplifiedStepPoints);
        }
      }

      if (groupPoints.isNotEmpty) {
        Color finalColor;
        if (currentGroupType == "non_transit") {
          finalColor = Colors.blue;
        } else {
          if (!transitColorMap.containsKey(currentTransitLine)) {
            transitColorMap[currentTransitLine!] = transitColors[transitColorIndex % transitColors.length];
            transitColorIndex++;
          }
          finalColor = transitColorMap[currentTransitLine]!;
        }

        // Walking dashed at tail too
        List<PatternItem>? pattern;
        if (currentGroupType == 'non_transit' && currentNonTransitMode == 'WALKING') {
          pattern = [PatternItem.dash(20), PatternItem.gap(12)];
        }

        polylines.add(Polyline(
          polylineId: PolylineId('group_${polylines.length}'),
          points: groupPoints,
          color: finalColor,
          width: 5,
          patterns: pattern ?? const <PatternItem>[],
          zIndex: currentGroupType == 'transit' ? 3 : 2,
        ));
      }
    }

    return polylines;
  }
}

/* File summary: DirectionService chooses a refresh cadence based on proximity and mode, fetches via ApiClient, simplifies
   polylines for efficiency, and persists results in RouteCache. It also groups steps into styled polylines (solid blue
   for driving, dashed blue for walking; limited palette for metro) to render clear map visuals. */
