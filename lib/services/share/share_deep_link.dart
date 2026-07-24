// lib/services/share/share_deep_link.dart
//
// PURE parsing of inbound share links. The app shell subscribes to app_links'
// Uri stream (see wiring notes) and feeds each Uri here; keeping the parse pure
// makes it fully unit-testable without the plugin.
//
// Accepted forms:
//   • App Links / web:   https://<domain>/j/{id}?t={token}
//   • Custom scheme:     geowake://j/{id}?t={token}

class ShareDeepLink {
  /// The opaque share session id (the `/j/{id}` slug).
  final String id;

  /// Optional HMAC token (`?t=`) for tamper verification.
  final String? token;

  const ShareDeepLink({required this.id, this.token});

  @override
  String toString() => 'ShareDeepLink(id: $id, token: ${token == null});';
}

class ShareDeepLinkParser {
  const ShareDeepLinkParser._();

  static const String customScheme = 'geowake';

  /// Parse [uri] into a [ShareDeepLink], or null if it is not a GeoWake share
  /// link. Never throws.
  static ShareDeepLink? parse(Uri? uri) {
    if (uri == null) return null;
    try {
      final segments = uri.pathSegments;
      String? id;

      if (uri.scheme == customScheme) {
        // geowake://j/{id}  → host == 'j', first segment == id
        if (uri.host == 'j' && segments.isNotEmpty) {
          id = segments.first;
        } else if (segments.length >= 2 && segments[segments.length - 2] == 'j') {
          id = segments.last;
        }
      } else {
        // https://<domain>/j/{id}
        final jIdx = segments.indexOf('j');
        if (jIdx >= 0 && jIdx + 1 < segments.length) {
          id = segments[jIdx + 1];
        }
      }

      if (id == null || id.trim().isEmpty) return null;
      // SECURITY: reject ids containing path separators or traversal sequences
      // to prevent URL path injection when the id is used in backend requests.
      final cleanId = id.trim();
      if (cleanId.contains('/') ||
          cleanId.contains('..') ||
          cleanId.contains('%2e') ||
          cleanId.contains('%2f')) {
        return null;
      }
      final token = uri.queryParameters['t'];
      return ShareDeepLink(
        id: cleanId,
        token: (token != null && token.isNotEmpty) ? token : null,
      );
    } catch (_) {
      return null;
    }
  }

  static ShareDeepLink? parseString(String? s) {
    if (s == null || s.isEmpty) return null;
    return parse(Uri.tryParse(s));
  }
}
