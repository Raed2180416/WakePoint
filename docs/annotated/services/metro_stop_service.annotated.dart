// Annotated copy of lib/services/metro_stop_service.dart
// Purpose: Explain fetching nearby transit stops via backend and destination validation.

import 'package:google_maps_flutter/google_maps_flutter.dart'; // LatLng
import 'package:geolocator/geolocator.dart'; // Distance calculations
import 'dart:developer' as dev; // Logging
import 'package:geowake2/services/api_client.dart'; // Backend proxy

class MetroStopService {
  static final ApiClient _apiClient = ApiClient.instance; // Shared API client

  // Fetch nearby transit stops through backend (avoids client-side API keys)
  static Future<List<TransitStop>> getNearbyTransitStops({ required LatLng location, double radius = 500 }) async {
    try {
      final results = await _apiClient.getNearbyTransitStations(
        location: '${location.latitude},${location.longitude}',
        radius: radius.toString(),
      );
      dev.log('Transit stops API response: Found ${results.length} stops', name: 'MetroStopService');
      return results.map((place) => TransitStop(
        name: place['name'],
        location: LatLng(place['geometry']['location']['lat'], place['geometry']['location']['lng']),
        placeId: place['place_id'],
      )).toList();
    } catch (e) {
      dev.log('Error fetching transit stops: $e', name: 'MetroStopService');
      return [];
    }
  }

  // Validate that destination is near a transit stop, and return the closest
  static Future<DestinationValidationResult> validateDestination({ required LatLng destination, double maxRadius = 500 }) async {
    final nearbyStops = await getNearbyTransitStops(location: destination, radius: maxRadius);
    if (nearbyStops.isNotEmpty) {
      final closestStop = nearbyStops.reduce((current, next) {
        final currentDistance = Geolocator.distanceBetween(destination.latitude, destination.longitude, current.location.latitude, current.location.longitude);
        final nextDistance = Geolocator.distanceBetween(destination.latitude, destination.longitude, next.location.latitude, next.location.longitude);
        return currentDistance < nextDistance ? current : next;
      });
      final distance = Geolocator.distanceBetween(destination.latitude, destination.longitude, closestStop.location.latitude, closestStop.location.longitude);
      return DestinationValidationResult(isValid: true, closestStop: closestStop, distance: distance);
    }
    return DestinationValidationResult(isValid: false, errorMessage: 'No transit stops found near the destination.');
  }

  // Ensure a metro route makes sense: start and destination stops should not be identical
  static Future<DestinationValidationResult> validateMetroRoute({ required LatLng startLocation, required LatLng destination, double maxRadius = 500 }) async {
    final destValidation = await validateDestination(destination: destination, maxRadius: maxRadius);
    if (!destValidation.isValid) {
      return DestinationValidationResult(isValid: false, errorMessage: 'Destination is not near any metro stops.');
    }
    final destStop = destValidation.closestStop!;

    final startStops = await getNearbyTransitStops(location: startLocation, radius: maxRadius);
    if (startStops.isNotEmpty) {
      final startStop = startStops.reduce((current, next) {
        final currentDistance = Geolocator.distanceBetween(startLocation.latitude, startLocation.longitude, current.location.latitude, current.location.longitude);
        final nextDistance = Geolocator.distanceBetween(startLocation.latitude, startLocation.longitude, next.location.latitude, next.location.longitude);
        return currentDistance < nextDistance ? current : next;
      });
      if (startStop.placeId == destStop.placeId) {
        return DestinationValidationResult(isValid: false, errorMessage: 'Destination metro stop is the same as your current transit stop. No metro route available.');
      }
    }
    return DestinationValidationResult(isValid: true, closestStop: destStop, distance: destValidation.distance);
  }
}

class TransitStop {
  final String name;     // Human-readable stop name
  final LatLng location; // Coordinates
  final String placeId;  // Backend/Places ID
  TransitStop({ required this.name, required this.location, required this.placeId });
}

class DestinationValidationResult {
  final bool isValid;            // Whether validation succeeded
  final TransitStop? closestStop; // If valid, closest stop to destination
  final double? distance;        // Distance to that stop
  final String? errorMessage;    // Human-friendly error when invalid
  DestinationValidationResult({ required this.isValid, this.closestStop, this.distance, this.errorMessage });
}
