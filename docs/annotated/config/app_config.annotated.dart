// Annotated copy of lib/config/app_config.dart
// Purpose: Document configuration access patterns and server-centric API routing.

class AppConfig { // Central place for app-level config values
  // API key is now handled by the secure server
  // Direct access is disabled for security
  static String get googleMapsApiKey { // Legacy getter intentionally throws to disallow direct key usage
    throw Exception('Direct API key access is disabled for security. All Google Maps API calls now go through the secure server via ApiClient.'); // Enforces server proxying pattern
  } // End googleMapsApiKey
  
  // For debugging purposes - shows API key source
  static String get apiKeySource { // Simple diagnostic to indicate where keys come from
    return 'Secure Server'; // Confirms server-side key management
  } // End apiKeySource
  
  // Server configuration (change for production)
  static const String serverBaseUrl = 'http://localhost:3000/api'; // Base URL for backend API (dev default)
  static const String appBundleId = 'com.yourcompany.geowake'; // Application identifier used by platforms/stores
} // End class AppConfig

/* File summary: AppConfig funnels config through server-backed APIs to avoid embedding secrets in the client. The
   thrown exception prevents accidental direct use of Google API keys in the app code, pushing all calls through ApiClient
   where authentication and metering are controlled. Update serverBaseUrl per environment. */
