class AppConfig {
  // API key is now handled by the secure server
  // Direct access is disabled for security
  static String get googleMapsApiKey {
    throw Exception(
      'Direct API key access is disabled for security. All Google Maps API calls now go through the secure server via ApiClient.',
    );
  }

  // For debugging purposes - shows API key source
  static String get apiKeySource {
    return 'Secure Server';
  }

  // Server configuration (aligned with production ApiClient base URL)
  static const String serverBaseUrl =
      'https://geowake-production.up.railway.app/api';
  static const String appBundleId = 'com.yourcompany.geowake';
}
