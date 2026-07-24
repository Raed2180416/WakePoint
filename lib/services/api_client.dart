// lib/services/api_client.dart
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geowake2/config/app_config.dart';
import 'dart:developer' as dev;

class ApiClient {
  static const String _baseUrl =
      'https://geowake-production.up.railway.app/api'; // Fixed: Added https:// and /api
  static const String _tokenKey = 'geowake_api_token';
  static const String _deviceIdKey = 'geowake_device_id';

  static ApiClient? _instance;
  static ApiClient get instance => _instance ??= ApiClient._internal();
  static bool testMode =
      false; // When true, _makeRequest returns canned responses and records bodies
  static Map<String, dynamic>? lastAutocompleteBody;
  static Map<String, dynamic>? lastPlaceDetailsBody;
  static Map<String, dynamic>? lastDirectionsBody;
  static final List<Map<String, dynamic>> directionsBodiesHistory =
      <Map<String, dynamic>>[];
  static int directionsCallCount = 0;

  /// Optional test-only canned responses for /maps/directions.
  /// - If [testDirectionsResponses] is non-empty, responses are returned FIFO.
  /// - Else if [testDirectionsResponse] is set, it is returned.
  /// - Else a minimal default directions payload is returned.
  static Map<String, dynamic>? testDirectionsResponse;
  static final List<Map<String, dynamic>> testDirectionsResponses =
      <Map<String, dynamic>>[];

  ApiClient._internal();

  /// Public accessor for the base URL (used by tests/config validation).
  static String get baseUrl => _baseUrl;

  /// Public accessor for the current auth token (used by candidate egress sink).
  String? get authToken => _authToken;

  String? _authToken;
  String? _deviceId;
  DateTime? _tokenExpiration;

  /// Initialize the API client - call this on app startup
  Future<void> initialize() async {
    dev.log('🚀 Initializing ApiClient...', name: 'ApiClient');
    // Prevent test mode in release builds
    assert(() {
      return true;
    }(), '');
    if (kReleaseMode) {
      testMode = false;
    }
    await _loadStoredCredentials();

    if (_authToken == null || _isTokenExpired()) {
      await _authenticate();
    }

    // Test connection
    await testConnection();
  }

  /// Test server connection
  Future<void> testConnection() async {
    try {
      dev.log('🔗 Testing connection to: $_baseUrl', name: 'ApiClient');
      final response = await http
          .get(
            Uri.parse('$_baseUrl/health'),
            headers: {'Content-Type': 'application/json'},
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        dev.log('✅ Server connection successful', name: 'ApiClient');
      } else {
        dev.log(
          '⚠️ Server responded with: ${response.statusCode}',
          name: 'ApiClient',
        );
      }
    } catch (e) {
      dev.log('❌ Server connection failed: $e', name: 'ApiClient');
      // Don't rethrow - connection test failure shouldn't break initialization
    }
  }

  /// Check if token is expired
  bool _isTokenExpired() {
    if (_tokenExpiration == null) return true;
    return DateTime.now().isAfter(
      _tokenExpiration!.subtract(const Duration(minutes: 5)),
    );
  }

  /// Load stored token and device ID
  Future<void> _loadStoredCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    _authToken = prefs.getString(_tokenKey);
    _deviceId = prefs.getString(_deviceIdKey);

    // Load token expiration if exists
    final expString = prefs.getString('${_tokenKey}_exp');
    if (expString != null) {
      _tokenExpiration = DateTime.tryParse(expString);
    }
  }

  /// Authenticate with server using bundle ID
  Future<void> _authenticate() async {
    try {
      dev.log('🔐 Authenticating with server...', name: 'ApiClient');

      // Single source of truth: import from AppConfig (BACKLOG #30)
      const bundleId = AppConfig.appBundleId;

      final response = await http
          .post(
            Uri.parse('$_baseUrl/auth/token'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'bundleId': bundleId}),
          )
          .timeout(const Duration(seconds: 15));

      dev.log(
        '📡 Auth response status: ${response.statusCode}',
        name: 'ApiClient',
      );
      if (!kReleaseMode) {
        dev.log('📡 Auth response body (redacted)', name: 'ApiClient');
      }

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] == true) {
          _authToken = data['token'];
          // Set token expiration (server returns expiresIn like '24h')
          _tokenExpiration = DateTime.now().add(const Duration(hours: 23));
          await _saveCredentials();
          dev.log('✅ Authentication successful', name: 'ApiClient');
        } else {
          throw Exception(
            'Authentication failed: ${data['error'] ?? 'Unknown error'}',
          );
        }
      } else {
        throw Exception('HTTP ${response.statusCode}: ${response.body}');
      }
    } catch (e) {
      dev.log('❌ Authentication failed: $e', name: 'ApiClient');
      rethrow;
    }
  }

  /// Save credentials to local storage
  Future<void> _saveCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    if (_authToken != null) await prefs.setString(_tokenKey, _authToken!);
    if (_deviceId != null) await prefs.setString(_deviceIdKey, _deviceId!);
    if (_tokenExpiration != null) {
      await prefs.setString(
        '${_tokenKey}_exp',
        _tokenExpiration!.toIso8601String(),
      );
    }
  }

  /// Build headers with authentication
  Map<String, String> _buildHeaders() {
    final headers = <String, String>{'Content-Type': 'application/json'};

    if (_authToken != null) {
      headers['Authorization'] = 'Bearer $_authToken';
    }

    return headers;
  }

  /// Make authenticated API request with auto-retry on auth failure
  Future<Map<String, dynamic>> _makeRequest(
    String method,
    String endpoint, {
    Map<String, dynamic>? body,
    Map<String, String>? queryParams,
  }) async {
    try {
      // Test mode: short-circuit HTTP and return canned payloads
      if (testMode) {
        // Record bodies for verification
        if (endpoint.contains('/maps/autocomplete')) {
          lastAutocompleteBody =
              body != null ? Map<String, dynamic>.from(body) : {};
          return {
            'predictions': [
              {'description': 'Test Place', 'place_id': 'test_place_id'},
            ],
            'status': 'OK',
          };
        }
        if (endpoint.contains('/maps/place-details')) {
          lastPlaceDetailsBody =
              body != null ? Map<String, dynamic>.from(body) : {};
          return {
            'result': {
              'name': 'Test Place',
              'geometry': {
                'location': {'lat': 12.34, 'lng': 56.78},
              },
              'formatted_address': '123 Test St',
            },
            'status': 'OK',
          };
        }
        if (endpoint.contains('/maps/directions')) {
          lastDirectionsBody =
              body != null ? Map<String, dynamic>.from(body) : {};
          directionsBodiesHistory.add(lastDirectionsBody!);
          directionsCallCount++;

          if (testDirectionsResponses.isNotEmpty) {
            return Map<String, dynamic>.from(
              testDirectionsResponses.removeAt(0),
            );
          }
          if (testDirectionsResponse != null) {
            return Map<String, dynamic>.from(testDirectionsResponse!);
          }

          // Minimal directions payload
          return {
            'routes': [
              {
                'overview_polyline': {'points': '}_se}Ff`miO??'},
                'legs': [
                  {
                    'steps': [],
                    'duration': {'value': 600},
                  },
                ],
              },
            ],
            'status': 'OK',
          };
        }
        // Default canned OK
        return {'status': 'OK'};
      }
      // Ensure we have a valid token
      if (_authToken == null || _isTokenExpired()) {
        dev.log(
          '🔄 Token missing or expired, authenticating...',
          name: 'ApiClient',
        );
        await _authenticate();
      }

      Uri uri = Uri.parse('$_baseUrl$endpoint');
      if (queryParams != null) {
        uri = uri.replace(queryParameters: queryParams);
      }

      dev.log(
        '📡 Making ${method.toUpperCase()} request to: $uri',
        name: 'ApiClient',
      );

      late http.Response response;
      final headers = _buildHeaders();

      switch (method.toUpperCase()) {
        case 'GET':
          response = await http
              .get(uri, headers: headers)
              .timeout(const Duration(seconds: 15));
          break;
        case 'POST':
          response = await http
              .post(
                uri,
                headers: headers,
                body: body != null ? jsonEncode(body) : null,
              )
              .timeout(const Duration(seconds: 15));
          break;
        default:
          throw Exception('Unsupported HTTP method: $method');
      }

      dev.log('📡 Response status: ${response.statusCode}', name: 'ApiClient');
      if (!kReleaseMode) {
        final preview =
            response.body.length > 200
                ? '${response.body.substring(0, 200)}...'
                : response.body;
        dev.log(
          '📡 Response body preview (redacted in release): $preview',
          name: 'ApiClient',
        );
      }

      // Handle token expiration
      if (response.statusCode == 401) {
        dev.log(
          '🔄 Token expired (401), re-authenticating...',
          name: 'ApiClient',
        );
        await _authenticate();

        // Retry the request with new token
        headers['Authorization'] = 'Bearer $_authToken';
        switch (method.toUpperCase()) {
          case 'GET':
            response = await http.get(uri, headers: headers);
            break;
          case 'POST':
            response = await http.post(
              uri,
              headers: headers,
              body: body != null ? jsonEncode(body) : null,
            );
            break;
        }
      }

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return data;
      } else {
        throw Exception('HTTP ${response.statusCode}: ${response.body}');
      }
    } catch (e) {
      dev.log('❌ API request failed: $e', name: 'ApiClient');
      rethrow;
    }
  }

  // ================================
  // GOOGLE MAPS API METHODS
  // ================================

  /// Get directions between two points
  Future<Map<String, dynamic>> getDirections({
    required String origin,
    required String destination,
    String mode = 'driving',
    String? transitMode,
    int? departureTime,
  }) async {
    dev.log(
      '🗺️ Getting directions from $origin to $destination',
      name: 'ApiClient',
    );

    final body = <String, dynamic>{
      'origin': origin,
      'destination': destination,
      'mode': mode,
      if (transitMode != null) 'transit_mode': transitMode,
      if (departureTime != null) 'departure_time': departureTime,
    };

    final result = await _makeRequest(
      'POST',
      '/maps/directions',
      body: body,
    ); // Fixed: Changed to POST
    dev.log(
      '🗺️ Directions response status: ${result['status']}',
      name: 'ApiClient',
    );
    return result; // Return the full result, not just 'data' field
  }

  /// Get autocomplete suggestions
  Future<List<Map<String, dynamic>>> getAutocompleteSuggestions({
    required String input,
    String? location,
    String? components,
    String? sessionToken,
  }) async {
    dev.log('🔍 Getting autocomplete for: "$input"', name: 'ApiClient');

    final body = <String, dynamic>{
      'input': input,
      if (location != null) 'location': location,
      if (components != null) 'components': components,
      if (sessionToken != null) 'sessiontoken': sessionToken,
    };

    final result = await _makeRequest(
      'POST',
      '/maps/autocomplete',
      body: body,
    ); // Fixed: Changed to POST

    // Handle the response structure from your server
    if (result['predictions'] != null) {
      final predictions = result['predictions'] as List;
      return predictions.map((p) => p as Map<String, dynamic>).toList();
    }

    return [];
  }

  /// Get place details
  Future<Map<String, dynamic>?> getPlaceDetails({
    required String placeId,
    String? sessionToken,
  }) async {
    dev.log('📍 Getting place details for: $placeId', name: 'ApiClient');

    final body = <String, String>{
      'place_id': placeId,
      if (sessionToken != null) 'sessiontoken': sessionToken,
    };

    final result = await _makeRequest(
      'POST',
      '/maps/place-details',
      body: body,
    ); // Fixed: Changed to POST

    // Handle the response structure from your server
    return result['result'] ?? result;
  }

  /// Get nearby transit stations
  Future<List<Map<String, dynamic>>> getNearbyTransitStations({
    required String location,
    String radius = '500',
  }) async {
    dev.log(
      '🚇 Getting nearby transit stations at: $location',
      name: 'ApiClient',
    );

    final body = <String, dynamic>{
      'location': location,
      'radius': radius,
      'type': 'transit_station',
    };

    final result = await _makeRequest(
      'POST',
      '/maps/nearby-search',
      body: body,
    ); // Fixed: Changed to POST

    // Handle the response structure from your server
    if (result['results'] != null) {
      final results = result['results'] as List;
      dev.log('🚇 Found ${results.length} transit stations', name: 'ApiClient');
      return results.map((r) => r as Map<String, dynamic>).toList();
    }

    dev.log('⚠️ No transit stations found in response', name: 'ApiClient');
    return [];
  }

  /// Get geocoding results
  Future<Map<String, dynamic>?> geocode({required String latlng}) async {
    dev.log('🌍 Geocoding: $latlng', name: 'ApiClient');

    final body = <String, String>{
      'address':
          latlng, // Note: server expects 'address' parameter for geocoding
    };

    final result = await _makeRequest('POST', '/maps/geocode', body: body);

    // Handle the response structure
    if (result['results'] != null && (result['results'] as List).isNotEmpty) {
      return (result['results'] as List).first;
    }

    return null;
  }
}
