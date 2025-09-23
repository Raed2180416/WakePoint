import 'package:geowake2/services/api_client.dart';
import 'dart:developer' as dev;

class PlacesService {
  final ApiClient _apiClient = ApiClient.instance;
  String? _sessionToken; // Google Places session token per search session
  DateTime? _sessionStartedAt;

  /// Returns an active session token, creating one if needed.
  /// Tokens should be reused for autocomplete + place details in a single session.
  String _ensureSessionToken() {
    final now = DateTime.now();
    // Rotate token if older than ~3 minutes or missing.
    if (_sessionToken == null || _sessionStartedAt == null || now.difference(_sessionStartedAt!) > const Duration(minutes: 3)) {
      _sessionToken = DateTime.now().millisecondsSinceEpoch.toString();
      _sessionStartedAt = now;
    }
    return _sessionToken!;
  }

  void endSession() {
    _sessionToken = null;
    _sessionStartedAt = null;
  }
  
  /// Fetches autocomplete suggestions through your secure server
  /// If countryCode is provided, results will be biased towards that country.
  Future<List<Map<String, dynamic>>> fetchAutocompleteResults(
    String query, {
    String? countryCode,
    double? lat,
    double? lng,
  }) async {
    try {
      final token = _ensureSessionToken();
      String? location;
      if (lat != null && lng != null) {
        location = '$lat,$lng';
      }
      
      String? components;
      if (countryCode != null && countryCode.isNotEmpty) {
        components = 'country:$countryCode';
      }
      
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
      dev.log("Error fetching autocomplete results: $e", name: "PlacesService");
      return [];
    }
  }
  
  /// Fetches detailed information about a place through your secure server
  Future<Map<String, dynamic>?> fetchPlaceDetails(String placeId) async {
    try {
      final token = _ensureSessionToken();
      final result = await _apiClient.getPlaceDetails(placeId: placeId, sessionToken: token);
      if (result != null) {
        final loc = result['geometry']['location'];
        return {
          'description': result['name'],
          'lat': loc['lat'],
          'lng': loc['lng'],
        };
      }
      return null;
    } catch (e) {
      dev.log("Error fetching place details: $e", name: "PlacesService");
      return null;
    }
  }
}