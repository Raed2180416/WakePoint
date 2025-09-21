import 'package:geowake2/services/api_client.dart';
import 'dart:developer' as dev;

class PlacesService {
  final ApiClient _apiClient = ApiClient.instance;
  
  /// Fetches autocomplete suggestions through your secure server
  /// If countryCode is provided, results will be biased towards that country.
  Future<List<Map<String, dynamic>>> fetchAutocompleteResults(
    String query, {
    String? countryCode,
    double? lat,
    double? lng,
  }) async {
    try {
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
      final result = await _apiClient.getPlaceDetails(placeId: placeId);
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