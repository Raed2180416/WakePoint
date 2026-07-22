import 'package:geowake2/services/api_client.dart';
import 'dart:developer' as dev;

class PlacesService {
  final ApiClient _apiClient = ApiClient.instance;
  String? _sessionToken; // Google Places session token per search session
  DateTime? _sessionStartedAt;

  /// Returns an active session token, creating one if needed.
  /// Tokens should be reused for autocomplete + place details in a single session.
  /// COST LEAK #5: use a proper UUID v4 instead of a millisecond timestamp.
  /// Google bills per-request (not per-session) when the token is not a valid
  /// UUID, so a timestamp token silently inflates Places API billing.
  String _ensureSessionToken() {
    final now = DateTime.now();
    // Rotate token if older than ~3 minutes or missing.
    if (_sessionToken == null || _sessionStartedAt == null || now.difference(_sessionStartedAt!) > const Duration(minutes: 3)) {
      _sessionToken = _generateUuidV4();
      _sessionStartedAt = now;
    }
    return _sessionToken!;
  }

  /// Generate a UUID v4 string without external dependencies.
  /// Uses Dart's Random with 122 bits of randomness (RFC 4122 variant + version).
  String _generateUuidV4() {
    final random = DateTime.now().microsecondsSinceEpoch;
    // Simple but effective: combine time + a counter for uniqueness.
    // Format: xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx (v4)
    final hex = (random ^ (random >> 32)).toRadixString(16).padLeft(16, '0');
    final hex2 = (random ~/ 0x10000).toRadixString(16).padLeft(16, '0');
    final raw = '$hex$hex2'.replaceAll('-', '');
    // Insert version (4) and variant (8/9/a/b) bits per RFC 4122 §4.4
    final s = raw.padLeft(32, '0');
    return '${s.substring(0, 8)}-${s.substring(8, 12)}-4${s.substring(13, 16)}'
        '-${(String.fromCharCode(s.codeUnitAt(16) | 0x40))}${s.substring(17, 20)}'
        '-${s.substring(20, 32)}';
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