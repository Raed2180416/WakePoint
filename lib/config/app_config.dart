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

  /// Base URL for hosted GTFS-derived city packs (recommended: GitHub Pages).
  ///
  /// Example:
  /// `https://<username>.github.io/geowake-gtfs`
  ///
  /// Leave empty to disable GTFS stop enrichment (app will fall back to uniform
  /// stop estimation for metro legs).
  static const String gtfsBaseUrl = '';

  // Unified bundle ID - must match:
  // - android/app/build.gradle
  // - android/app/build.gradle.kts
  // - geowake-server/src/config/config.js (APP_BUNDLE_ID env)
  static const String appBundleId = 'com.geowake.app';
}
