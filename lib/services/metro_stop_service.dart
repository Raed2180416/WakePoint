import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'dart:developer' as dev;
import 'package:geowake2/services/api_client.dart';

class MetroStopService {
  static final ApiClient _apiClient = ApiClient.instance;

  // Fetch nearby transit stops using your secure server instead of direct API calls
  static Future<List<TransitStop>> getNearbyTransitStops({
    required LatLng location,
    double radius = 500, // meters, adjust as needed
  }) async {
    try {
      final results = await _apiClient.getNearbyTransitStations(
        location: '${location.latitude},${location.longitude}',
        radius: radius.toString(),
      );
      
      dev.log("Transit stops API response: Found ${results.length} stops", name: "MetroStopService");
      
      return results.map((place) => TransitStop(
        name: place['name'],
        location: LatLng(
          place['geometry']['location']['lat'],
          place['geometry']['location']['lng'],
        ),
        placeId: place['place_id'],
      )).toList();
    } catch (e) {
      dev.log("Error fetching transit stops: $e", name: "MetroStopService");
      return [];
    }
  }

  // Validate destination proximity to transit stops.
  static Future<DestinationValidationResult> validateDestination({
    required LatLng destination,
    double maxRadius = 500, // meters
  }) async {
    final List<TransitStop> nearbyStops = await getNearbyTransitStops(
      location: destination,
      radius: maxRadius,
    );

    if (nearbyStops.isNotEmpty) {
      // Find the closest stop.
      TransitStop closestStop = nearbyStops.reduce((current, next) {
        double currentDistance = Geolocator.distanceBetween(
          destination.latitude,
          destination.longitude,
          current.location.latitude,
          current.location.longitude,
        );
        double nextDistance = Geolocator.distanceBetween(
          destination.latitude,
          destination.longitude,
          next.location.latitude,
          next.location.longitude,
        );
        return currentDistance < nextDistance ? current : next;
      });

      double distance = Geolocator.distanceBetween(
        destination.latitude,
        destination.longitude,
        closestStop.location.latitude,
        closestStop.location.longitude,
      );

      return DestinationValidationResult(
        isValid: true,
        closestStop: closestStop,
        distance: distance,
      );
    }

    return DestinationValidationResult(
      isValid: false,
      errorMessage: "No transit stops found near the destination.",
    );
  }

  /// New method: Validates that a metro route exists from the user's starting location
  /// to the destination (i.e. the destination's transit stop is not identical to a transit stop near the user).
  static Future<DestinationValidationResult> validateMetroRoute({
    required LatLng startLocation,
    required LatLng destination,
    double maxRadius = 500,
  }) async {
    // Validate destination transit stops.
    DestinationValidationResult destValidation = await validateDestination(
      destination: destination,
      maxRadius: maxRadius,
    );
    if (!destValidation.isValid) {
      return DestinationValidationResult(
        isValid: false,
        errorMessage: "Destination is not near any metro stops.",
      );
    }
    TransitStop destStop = destValidation.closestStop!;
    
    // Get nearby transit stops for the user's start location.
    List<TransitStop> startStops = await getNearbyTransitStops(
      location: startLocation,
      radius: maxRadius,
    );
    if (startStops.isNotEmpty) {
      // Find the closest stop for the start location.
      TransitStop startStop = startStops.reduce((current, next) {
        double currentDistance = Geolocator.distanceBetween(
            startLocation.latitude, startLocation.longitude, current.location.latitude, current.location.longitude);
        double nextDistance = Geolocator.distanceBetween(
            startLocation.latitude, startLocation.longitude, next.location.latitude, next.location.longitude);
        return currentDistance < nextDistance ? current : next;
      });
      // If the start transit stop is the same as the destination transit stop, reject the route.
      if (startStop.placeId == destStop.placeId) {
        return DestinationValidationResult(
          isValid: false,
          errorMessage: "Destination metro stop is the same as your current transit stop. No metro route available.",
        );
      }
    }
    // If no transit stop is found near the start location, that's acceptable (the user may use another means to reach the destination stop).
    return DestinationValidationResult(
      isValid: true,
      closestStop: destStop,
      distance: destValidation.distance,
    );
  }
}

class TransitStop {
  final String name;
  final LatLng location;
  final String placeId;

  TransitStop({
    required this.name,
    required this.location,
    required this.placeId,
  });
}

class DestinationValidationResult {
  final bool isValid;
  final TransitStop? closestStop;
  final double? distance;
  final String? errorMessage; // New field for error messaging

  DestinationValidationResult({
    required this.isValid,
    this.closestStop,
    this.distance,
    this.errorMessage,
  });
}