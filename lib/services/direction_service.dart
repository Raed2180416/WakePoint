
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'polyline_decoder.dart';
import 'polyline_simplifier.dart';
import 'package:geowake2/services/api_client.dart'; // ADD THIS IMPORT
import 'dart:developer' as dev;

class DirectionService {
  final ApiClient _apiClient = ApiClient.instance;
  Map<String, dynamic>? _cachedDirections;
  DateTime? _lastFetchTime;

  // Tiered intervals for updating directions.
  final Duration farInterval = const Duration(minutes: 15);
  final Duration midInterval = const Duration(minutes: 7);
  final Duration nearInterval = const Duration(minutes: 3);

  DirectionService();

  /// Fetches directions using a tiered strategy through your secure API.
  Future<Map<String, dynamic>> getDirections(
    double startLat,
    double startLng,
    double endLat,
    double endLng, {
    required bool isDistanceMode,
    required double threshold,
    required bool transitMode,
    bool forceRefresh = false,
  }) async {
    // Calculate the straight-line distance in meters.
    double straightDistance = Geolocator.distanceBetween(startLat, startLng, endLat, endLng);

    // Determine the update interval.
    Duration updateInterval;
    if (isDistanceMode) {
      double thresholdMeters = threshold * 1000;
      if (straightDistance > 5 * thresholdMeters) {
        updateInterval = farInterval;
      } else if (straightDistance > 2 * thresholdMeters) {
        updateInterval = midInterval;
      } else {
        updateInterval = nearInterval;
      }
    } else {
      updateInterval = nearInterval;
    }

    // Return cached data if available and recent.
    if (!forceRefresh && _cachedDirections != null && _lastFetchTime != null) {
      final elapsed = DateTime.now().difference(_lastFetchTime!);
      if (elapsed < updateInterval) {
        return _cachedDirections!;
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

      // --- Simplify & compress the overview polyline ---
      if (directions['routes'] != null && directions['routes'].isNotEmpty) {
        final route = directions['routes'][0];
        if (route['overview_polyline'] != null && route['overview_polyline']['points'] != null) {
          final String encodedPolyline = route['overview_polyline']['points'] as String;
          // Decode the polyline.
          List<LatLng> decodedPoints = decodePolyline(encodedPolyline);
          // Simplify with a tolerance of 10 meters.
          List<LatLng> simplifiedPoints = PolylineSimplifier.simplifyPolyline(decodedPoints, 10);
          // Compress the simplified polyline.
          String compressedPolyline = PolylineSimplifier.compressPolyline(simplifiedPoints);
          // Add the simplified compressed polyline to the response.
          route['simplified_polyline'] = compressedPolyline;
        }
      }

      _cachedDirections = directions;
      _lastFetchTime = DateTime.now();
      return directions;

    } catch (e) {
      dev.log("Error fetching directions via API client: $e", name: "DirectionService");
      throw Exception("Failed to fetch directions: $e");
    }
  }

  // Rest of the class remains the same...
  List<Polyline> buildSegmentedPolylines(Map<String, dynamic> directions, bool transitMode) {
    List<Polyline> polylines = [];
    if (directions['routes'] == null || directions['routes'].isEmpty) return polylines;

  Map<String, Color> transitColorMap = {};
  // Only use green and purple for metro transit lines
  List<Color> transitColors = [Colors.green, Colors.purple];
    int transitColorIndex = 0;

    for (var leg in directions['routes'][0]['legs']) {
      List<dynamic> steps = leg['steps'];
      if (steps.isEmpty) continue;

      List<LatLng> groupPoints = [];
      String currentGroupType;
      String? currentTransitLine;

      // Initialize first step
      var firstStep = steps[0];
      String firstMode = firstStep['travel_mode'];
      bool isFirstTransitMetro = false;
      if (firstMode == 'TRANSIT' && transitMode) {
        if (firstStep.containsKey('transit_details') && firstStep['transit_details'] != null) {
          var transitDetails = firstStep['transit_details'];
          var vehicleType = transitDetails['line']['vehicle']['type'];
          isFirstTransitMetro = vehicleType == 'SUBWAY' || vehicleType == 'HEAVY_RAIL';
          if (isFirstTransitMetro) {
            currentGroupType = "transit";
            currentTransitLine = transitDetails['line']['short_name'] ?? transitDetails['line']['name'];
          } else {
            currentGroupType = "non_transit";
            currentTransitLine = null;
          }
        } else {
          currentGroupType = "non_transit";
          currentTransitLine = null;
        }
      } else {
        currentGroupType = "non_transit";
        currentTransitLine = null;
      }
      // Decode, simplify, then add first step points.
      List<LatLng> rawPoints = decodePolyline(firstStep['polyline']['points']);
      List<LatLng> simplifiedPoints = PolylineSimplifier.simplifyPolyline(rawPoints, 10);
      groupPoints.addAll(simplifiedPoints);

      for (int i = 1; i < steps.length; i++) {
        var step = steps[i];
        String stepMode = step['travel_mode'];
        String stepGroupType = "non_transit";
        String? stepTransitLine;
        bool isStepTransitMetro = false;

        if (stepMode == 'TRANSIT' && transitMode) {
          if (step.containsKey('transit_details') && step['transit_details'] != null) {
            var transitDetails = step['transit_details'];
            var vehicleType = transitDetails['line']['vehicle']['type'];
            isStepTransitMetro = vehicleType == 'SUBWAY' || vehicleType == 'HEAVY_RAIL';
            if (isStepTransitMetro) {
              stepGroupType = "transit";
              stepTransitLine = transitDetails['line']['short_name'] ?? transitDetails['line']['name'];
            } else {
              stepGroupType = "non_transit";
              stepTransitLine = null;
            }
          }
        }

        bool sameGroup = false;
        if (currentGroupType == "non_transit" && stepGroupType == "non_transit") {
          sameGroup = true;
        } else if (currentGroupType == "transit" && stepGroupType == "transit") {
          sameGroup = (currentTransitLine == stepTransitLine);
        }

        if (sameGroup) {
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

          polylines.add(Polyline(
            polylineId: PolylineId('group_${polylines.length}'),
            points: groupPoints,
            color: groupColor,
            width: 4,
          ));

          groupPoints = [];
          currentGroupType = stepGroupType;
          currentTransitLine = stepTransitLine;
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

        polylines.add(Polyline(
          polylineId: PolylineId('group_${polylines.length}'),
          points: groupPoints,
          color: finalColor,
          width: 4,
        ));
      }
    }

    return polylines;
  }
}