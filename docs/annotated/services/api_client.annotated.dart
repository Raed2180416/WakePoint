// Annotated copy of lib/services/api_client.dart
// Purpose: Explain backend auth, request flow, test mode, and Maps wrappers.

import 'dart:convert'; // JSON encode/decode
import 'package:flutter/foundation.dart'; // kReleaseMode
import 'package:http/http.dart' as http; // HTTP client
import 'package:shared_preferences/shared_preferences.dart'; // Persist token/device info
import 'dart:developer' as dev; // Logging

class ApiClient {
  static const String _baseUrl = 'https://geowake-production.up.railway.app/api'; // Server base
  static const String _tokenKey = 'geowake_api_token';
  static const String _deviceIdKey = 'geowake_device_id';

  static ApiClient? _instance; // Singleton
  static ApiClient get instance => _instance ??= ApiClient._internal();
  static bool testMode = false; // When true, return canned responses and record bodies
  static Map<String, dynamic>? lastAutocompleteBody;
  static Map<String, dynamic>? lastPlaceDetailsBody;
  static Map<String, dynamic>? lastDirectionsBody;
  static int directionsCallCount = 0;

  ApiClient._internal();

  String? _authToken;        // Bearer token
  String? _deviceId;         // Optional device ID (reserved)
  DateTime? _tokenExpiration; // Expiry timestamp

  // Initialize client: load credentials, auth if needed, ping health
  Future<void> initialize() async {
    dev.log('🚀 Initializing ApiClient...', name: 'ApiClient');
    assert(() { return true; }(), '');
    if (kReleaseMode) testMode = false; // Force off in release
    await _loadStoredCredentials();
    if (_authToken == null || _isTokenExpired()) { await _authenticate(); }
    await testConnection();
  }

  Future<void> testConnection() async {
    try {
      dev.log('🔗 Testing connection to: $_baseUrl', name: 'ApiClient');
      final response = await http.get(Uri.parse('$_baseUrl/health'), headers: {'Content-Type': 'application/json'}).timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) dev.log('✅ Server connection successful', name: 'ApiClient');
      else dev.log('⚠️ Server responded with: ${response.statusCode}', name: 'ApiClient');
    } catch (e) { dev.log('❌ Server connection failed: $e', name: 'ApiClient'); }
  }

  bool _isTokenExpired() { if (_tokenExpiration == null) return true; return DateTime.now().isAfter(_tokenExpiration!.subtract(const Duration(minutes: 5))); }

  Future<void> _loadStoredCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    _authToken = prefs.getString(_tokenKey);
    _deviceId = prefs.getString(_deviceIdKey);
    final expString = prefs.getString('${_tokenKey}_exp');
    if (expString != null) _tokenExpiration = DateTime.tryParse(expString);
  }

  Future<void> _authenticate() async {
    try {
      dev.log('🔐 Authenticating with server...', name: 'ApiClient');
      final response = await http.post(
        Uri.parse('$_baseUrl/auth/token'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'bundleId': 'com.yourcompany.geowake2'}),
      ).timeout(const Duration(seconds: 15));
      dev.log('📡 Auth response status: ${response.statusCode}', name: 'ApiClient');
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] == true) {
          _authToken = data['token'];
          _tokenExpiration = DateTime.now().add(const Duration(hours: 23));
          await _saveCredentials();
          dev.log('✅ Authentication successful', name: 'ApiClient');
        } else {
          throw Exception('Authentication failed: ${data['error'] ?? 'Unknown error'}');
        }
      } else {
        throw Exception('HTTP ${response.statusCode}: ${response.body}');
      }
    } catch (e) { dev.log('❌ Authentication failed: $e', name: 'ApiClient'); rethrow; }
  }

  Future<void> _saveCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    if (_authToken != null) await prefs.setString(_tokenKey, _authToken!);
    if (_deviceId != null) await prefs.setString(_deviceIdKey, _deviceId!);
    if (_tokenExpiration != null) await prefs.setString('${_tokenKey}_exp', _tokenExpiration!.toIso8601String());
  }

  Map<String, String> _buildHeaders() {
    final headers = <String, String>{'Content-Type': 'application/json'};
    if (_authToken != null) headers['Authorization'] = 'Bearer $_authToken';
    return headers;
  }

  // Core request with token handling, retry on 401, and test-mode short-circuit
  Future<Map<String, dynamic>> _makeRequest(String method, String endpoint, { Map<String, dynamic>? body, Map<String, String>? queryParams, }) async {
    try {
      if (testMode) {
        if (endpoint.contains('/maps/autocomplete')) { lastAutocompleteBody = body != null ? Map<String, dynamic>.from(body) : {}; return { 'predictions': [ { 'description': 'Test Place', 'place_id': 'test_place_id' } ], 'status': 'OK' }; }
        if (endpoint.contains('/maps/place-details')) { lastPlaceDetailsBody = body != null ? Map<String, dynamic>.from(body) : {}; return { 'result': { 'name': 'Test Place', 'geometry': { 'location': {'lat': 12.34, 'lng': 56.78} }, 'formatted_address': '123 Test St' }, 'status': 'OK' }; }
        if (endpoint.contains('/maps/directions')) { lastDirectionsBody = body != null ? Map<String, dynamic>.from(body) : {}; directionsCallCount++; return { 'routes': [ { 'overview_polyline': {'points': '}_se}Ff`miO??'}, 'legs': [ { 'steps': [], 'duration': {'value': 600} } ] } ], 'status': 'OK' }; }
        return {'status': 'OK'};
      }
      if (_authToken == null || _isTokenExpired()) { dev.log('🔄 Token missing or expired, authenticating...', name: 'ApiClient'); await _authenticate(); }
      Uri uri = Uri.parse('$_baseUrl$endpoint'); if (queryParams != null) { uri = uri.replace(queryParameters: queryParams); }
      dev.log('📡 Making ${method.toUpperCase()} request to: $uri', name: 'ApiClient');
      late http.Response response; final headers = _buildHeaders();
      switch (method.toUpperCase()) {
        case 'GET': response = await http.get(uri, headers: headers).timeout(const Duration(seconds: 15)); break;
        case 'POST': response = await http.post(uri, headers: headers, body: body != null ? jsonEncode(body) : null).timeout(const Duration(seconds: 15)); break;
        default: throw Exception('Unsupported HTTP method: $method');
      }
      dev.log('📡 Response status: ${response.statusCode}', name: 'ApiClient');
      if (!kReleaseMode) { final preview = response.body.length > 200 ? '${response.body.substring(0, 200)}...' : response.body; dev.log('📡 Response body preview (redacted in release): $preview', name: 'ApiClient'); }
      if (response.statusCode == 401) {
        dev.log('🔄 Token expired (401), re-authenticating...', name: 'ApiClient'); await _authenticate();
        final headers2 = _buildHeaders();
        switch (method.toUpperCase()) {
          case 'GET': response = await http.get(uri, headers: headers2); break;
          case 'POST': response = await http.post(uri, headers: headers2, body: body != null ? jsonEncode(body) : null); break;
        }
      }
      if (response.statusCode == 200) return jsonDecode(response.body) as Map<String, dynamic>;
      throw Exception('HTTP ${response.statusCode}: ${response.body}');
    } catch (e) { dev.log('❌ API request failed: $e', name: 'ApiClient'); rethrow; }
  }

  // Maps wrappers
  Future<Map<String, dynamic>> getDirections({ required String origin, required String destination, String mode = 'driving', String? transitMode, }) async {
    dev.log('🗺️ Getting directions from $origin to $destination', name: 'ApiClient');
    final body = <String, dynamic>{ 'origin': origin, 'destination': destination, 'mode': mode, if (transitMode != null) 'transit_mode': transitMode };
    return await _makeRequest('POST', '/maps/directions', body: body);
  }

  Future<List<Map<String, dynamic>>> getAutocompleteSuggestions({ required String input, String? location, String? components, String? sessionToken, }) async {
    dev.log('🔍 Getting autocomplete for: "$input"', name: 'ApiClient');
    final body = <String, dynamic>{ 'input': input, if (location != null) 'location': location, if (components != null) 'components': components, if (sessionToken != null) 'sessiontoken': sessionToken };
    final result = await _makeRequest('POST', '/maps/autocomplete', body: body);
    if (result['predictions'] != null) { final predictions = result['predictions'] as List; return predictions.map((p) => p as Map<String, dynamic>).toList(); }
    return [];
  }

  Future<Map<String, dynamic>?> getPlaceDetails({ required String placeId, String? sessionToken, }) async {
    dev.log('📍 Getting place details for: $placeId', name: 'ApiClient');
    final body = <String, String>{ 'place_id': placeId, if (sessionToken != null) 'sessiontoken': sessionToken };
    final result = await _makeRequest('POST', '/maps/place-details', body: body);
    return result['result'] ?? result;
  }

  Future<List<Map<String, dynamic>>> getNearbyTransitStations({ required String location, String radius = '500', }) async {
    dev.log('🚇 Getting nearby transit stations at: $location', name: 'ApiClient');
    final body = <String, dynamic>{ 'location': location, 'radius': radius, 'type': 'transit_station' };
    final result = await _makeRequest('POST', '/maps/nearby-search', body: body);
    if (result['results'] != null) { final results = result['results'] as List; return results.map((r) => r as Map<String, dynamic>).toList(); }
    return [];
  }

  Future<Map<String, dynamic>?> geocode({ required String latlng, }) async {
    dev.log('🌍 Geocoding: $latlng', name: 'ApiClient');
    final body = <String, String>{ 'address': latlng };
    final result = await _makeRequest('POST', '/maps/geocode', body: body);
    if (result['results'] != null && (result['results'] as List).isNotEmpty) { return (result['results'] as List).first; }
    return null;
  }
}
