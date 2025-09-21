// lib/services/api_client.dart
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:developer' as dev;

class ApiClient {
  static const String _baseUrl = 'http://localhost:3000/api'; // Your server
  static const String _tokenKey = 'geowake_api_token';
  static const String _deviceIdKey = 'geowake_device_id';
  
  static ApiClient? _instance;
  static ApiClient get instance => _instance ??= ApiClient._internal();
  
  ApiClient._internal();
  
  String? _authToken;
  String? _deviceId;
  
  /// Initialize the API client - call this on app startup
  Future<void> initialize() async {
    await _loadStoredCredentials();
    
    if (_authToken == null || _deviceId == null) {
      await _registerDevice();
    }
  }
  
  /// Load stored token and device ID
  Future<void> _loadStoredCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    _authToken = prefs.getString(_tokenKey);
    _deviceId = prefs.getString(_deviceIdKey);
  }
  
  /// Register device with server and get JWT token
  Future<void> _registerDevice() async {
    try {
      // Generate or load device ID
      if (_deviceId == null) {
        final deviceInfo = DeviceInfoPlugin();
        if (Platform.isAndroid) {
          final androidInfo = await deviceInfo.androidInfo;
          _deviceId = androidInfo.id;
        } else if (Platform.isIOS) {
          final iosInfo = await deviceInfo.iosInfo;
          _deviceId = iosInfo.identifierForVendor;
        } else {
          _deviceId = 'dev-${DateTime.now().millisecondsSinceEpoch}';
        }
      }
      
      final response = await http.post(
        Uri.parse('$_baseUrl/auth/register-device'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'deviceId': _deviceId,
          'appVersion': '1.0.0',
          'bundleId': 'com.yourcompany.geowake',
        }),
      );
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success']) {
          _authToken = data['token'];
          await _saveCredentials();
          dev.log('✅ Device registered with server', name: 'ApiClient');
        } else {
          throw Exception('Registration failed: ${data['error']}');
        }
      } else {
        throw Exception('HTTP ${response.statusCode}: ${response.body}');
      }
    } catch (e) {
      dev.log('❌ Device registration failed: $e', name: 'ApiClient');
      rethrow;
    }
  }
  
  /// Save credentials to local storage
  Future<void> _saveCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    if (_authToken != null) await prefs.setString(_tokenKey, _authToken!);
    if (_deviceId != null) await prefs.setString(_deviceIdKey, _deviceId!);
  }
  
  /// Build headers with authentication
  Map<String, String> _buildHeaders() {
    return {
      'Content-Type': 'application/json',
      if (_authToken != null) 'Authorization': 'Bearer $_authToken',
    };
  }
  
  /// Make authenticated API request with auto-retry on auth failure
  Future<Map<String, dynamic>> _makeRequest(
    String method,
    String endpoint,
    Map<String, String> queryParams,
  ) async {
    try {
      final uri = Uri.parse('$_baseUrl$endpoint').replace(queryParameters: queryParams);
      
      late http.Response response;
      switch (method.toUpperCase()) {
        case 'GET':
          response = await http.get(uri, headers: _buildHeaders());
          break;
        default:
          throw Exception('Unsupported HTTP method: $method');
      }
      
      // Handle token expiration
      if (response.statusCode == 401) {
        dev.log('🔄 Token expired, re-registering device...', name: 'ApiClient');
        await _registerDevice();
        
        // Retry the request with new token
        response = await http.get(uri, headers: _buildHeaders());
      }
      
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      
      if (response.statusCode == 200 && data['success']) {
        return data;
      } else {
        throw Exception('API Error: ${data['error'] ?? 'Unknown error'}');
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
  }) async {
    final params = <String, String>{
      'origin': origin,
      'destination': destination,
      'mode': mode,
      if (transitMode != null) 'transit_mode': transitMode,
    };
    
    final result = await _makeRequest('GET', '/maps/directions', params);
    return result['data'];
  }
  
  /// Get autocomplete suggestions
  Future<List<Map<String, dynamic>>> getAutocompleteSuggestions({
    required String input,
    String? location,
    String? components,
  }) async {
    final params = <String, String>{
      'input': input,
      if (location != null) 'location': location,
      if (components != null) 'components': components,
    };
    
    final result = await _makeRequest('GET', '/maps/autocomplete', params);
    final predictions = result['data']['predictions'] as List;
    return predictions.map((p) => p as Map<String, dynamic>).toList();
  }
  
  /// Get place details
  Future<Map<String, dynamic>?> getPlaceDetails({
    required String placeId,
  }) async {
    final params = <String, String>{
      'place_id': placeId,
    };
    
    final result = await _makeRequest('GET', '/maps/place-details', params);
    return result['data']['result'];
  }
  
  /// Get nearby transit stations
  Future<List<Map<String, dynamic>>> getNearbyTransitStations({
    required String location,
    String radius = '500',
  }) async {
    final params = <String, String>{
      'location': location,
      'radius': radius,
      'type': 'transit_station',
    };
    
    final result = await _makeRequest('GET', '/maps/nearby-search', params);
    final results = result['data']['results'] as List;
    return results.map((r) => r as Map<String, dynamic>).toList();
  }
}