// lib/services/share/share_backend_config.dart
//
// The ONE place the founder configures GeoWake journey-sharing to point at the
// deployed Railway backend. Everything is additive and fail-safe: with no
// configuration the app stays on the fully-offline NoopShareBackend and basic
// share still works end-to-end.
//
// Set these at build time (no code edit needed):
//   flutter build apk \
//     --dart-define=GEOWAKE_SHARE_BASE_URL=https://your-app.up.railway.app \
//     --dart-define=GEOWAKE_SHARE_TOKEN=<bearer-token> \
//     --dart-define=GEOWAKE_SHARE_DOMAIN=https://your-app-links-domain
//
// …or just replace the defaultValue strings below.

import 'followed_rides_service.dart';
import 'journey_share_service.dart';
import 'live_share_backend.dart';
import 'share_link_builder.dart';

class ShareBackendConfig {
  const ShareBackendConfig._();

  /// Railway base URL. Defaults to the deployed geowake-share service (a public
  /// URL, safe to commit). Live tracking additionally needs [authToken] injected
  /// at build via --dart-define=GEOWAKE_SHARE_TOKEN=... ; without it, BASIC share
  /// (the message + /j link via the OS share sheet) still works — only the live
  /// ping/follow path is inert (fail-safe). Empty ⇒ fully offline Noop backend.
  static const String baseUrl = String.fromEnvironment(
    'GEOWAKE_SHARE_BASE_URL',
    defaultValue: 'https://geowake-share-production.up.railway.app',
  );

  /// Founder-provisioned bearer token the server checks on every write/read.
  static const String authToken = String.fromEnvironment(
    'GEOWAKE_SHARE_TOKEN',
    defaultValue: '',
  );

  /// App-Links domain that serves `/j/{id}` and `/.well-known/assetlinks.json`.
  /// Defaults to the builder's placeholder until the founder registers a domain.
  static const String appLinksDomain = String.fromEnvironment(
    'GEOWAKE_SHARE_DOMAIN',
    defaultValue: ShareLinkBuilder.defaultDomain,
  );

  /// True once a real Railway URL is configured.
  static bool get isLiveConfigured => baseUrl.trim().isNotEmpty;

  /// Build the transport: a live HttpShareBackend when configured, else Noop.
  static ShareBackend buildBackend() {
    if (!isLiveConfigured) return const NoopShareBackend();
    return HttpShareBackend(
      baseUrl: baseUrl.trim(),
      authToken: authToken.trim().isEmpty ? null : authToken.trim(),
    );
  }

  /// Wire both the SHARER (JourneyShareService) and the FOLLOWER
  /// (FollowedRidesService) to the configured backend + domain. Call once at
  /// app init (fire-and-forget). Idempotent and fail-safe.
  static Future<void> configure() async {
    final backend = buildBackend();

    // Sharer push side.
    JourneyShareService.instance.backend = backend;
    JourneyShareService.instance.domain = appLinksDomain;

    // Follower read side: only a backend that can serve reads is a reader.
    FollowedRidesService.instance.attachReader(
        backend is ShareStatusReader ? backend as ShareStatusReader : null);
    await FollowedRidesService.instance.init();
  }
}
