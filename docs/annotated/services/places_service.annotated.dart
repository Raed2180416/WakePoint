// Annotated copy of lib/services/places_service.dart
// Purpose: Explain session-tokened autocomplete and place details via secure backend.

import 'package:geowake2/services/api_client.dart'; // App-secured API proxy
import 'dart:developer' as dev; // Logging

class PlacesService {
  final ApiClient _apiClient = ApiClient.instance; // Singleton API client
  String? _sessionToken;           // Google Places session token
  DateTime? _sessionStartedAt;     // When the current token was created

  // Ensure a session token exists and is fresh (rotate ~3 minutes)
  String _ensureSessionToken() {
    final now = DateTime.now();
    if (_sessionToken == null || _sessionStartedAt == null || now.difference(_sessionStartedAt!) > const Duration(minutes: 3)) {
      _sessionToken = DateTime.now().millisecondsSinceEpoch.toString();
      _sessionStartedAt = now;
    }
    return _sessionToken!;
  }

  void endSession() { _sessionToken = null; _sessionStartedAt = null; }

  // Fetch autocomplete results from backend (which calls Google securely)
  Future<List<Map<String, dynamic>>> fetchAutocompleteResults(
    String query, {
    String? countryCode,
    double? lat,
    double? lng,
  }) async {
    try {
      final token = _ensureSessionToken();
      String? location;
      if (lat != null && lng != null) location = '$lat,$lng';
      String? components;
      if (countryCode != null && countryCode.isNotEmpty) components = 'country:$countryCode';

      final results = await _apiClient.getAutocompleteSuggestions(
        input: query,
        location: location,
        components: components,
        sessionToken: token,
      );

      return results.map((item) => {
        'description': item['description'],
        'place_id': item['place_id'],
        'isLocal': false,
      }).toList();
    } catch (e) {
      dev.log('Error fetching autocomplete results: $e', name: 'PlacesService');
      return [];
    }
  }

  // Resolve a placeId to coordinates via backend, observing the same session token
  Future<Map<String, dynamic>?> fetchPlaceDetails(String placeId) async {
    try {
      final token = _ensureSessionToken();
      final result = await _apiClient.getPlaceDetails(placeId: placeId, sessionToken: token);
      if (result != null) {
        final loc = result['geometry']['location'];
        return { 'description': result['name'], 'lat': loc['lat'], 'lng': loc['lng'] };
      }
      return null;
    } catch (e) {
      dev.log('Error fetching place details: $e', name: 'PlacesService');
      return null;
    }
  }
}
