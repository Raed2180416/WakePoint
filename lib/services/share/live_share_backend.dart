// lib/services/share/live_share_backend.dart
//
// The BACKEND CONTRACT for GeoWake journey sharing — a narrow, pluggable
// interface the client depends on so it works fully OFFLINE by default and can
// be upgraded to live tracking without touching any client feature code.
//
//   • NoopShareBackend  — the DEFAULT. supportsLive == false. Basic share works
//     end-to-end with a client-generated id and no network. Live pings / arrived
//     pushes are silently dropped.
//   • HttpShareBackend  — skeleton that maps this contract onto the founder's
//     Railway server (`/v1/share`). The server stores ONLY the latest snapshot
//     with a TTL, then hard-deletes; it never routes shares into any data /
//     analytics pipeline. See docs/share/BACKEND_CONTRACT.md.
//
// CORE-SAFETY: every method is best-effort. Implementations must swallow their
// own transport errors and return quietly — a backend failure can never block
// the app, the alarm, or the free basic-share loop.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'journey_share_models.dart';

/// The pluggable share transport. Named methods match the Railway contract:
/// createShare / pushLocation / markArrived / revoke.
abstract class ShareBackend {
  /// True only if this backend can carry live coarse-position updates. The
  /// client uses this to decide whether to bind tracking pings at all.
  bool get supportsLive;

  /// Register a share on the server. Returns the server-side id (which the
  /// client stores as [ShareSession.backendId]) or null if the backend is
  /// offline / declined — in which case the client's own opaque id is used.
  Future<String?> createShare(ShareSession session);

  /// Push the LATEST coarse position for [shareId]. No history is sent or kept.
  Future<void> pushLocation(String shareId, ShareSnapshot snapshot);

  /// Mark the journey arrived — the trigger the server turns into the
  /// recipient's "arrived safely" notification (FCM / SMS).
  Future<void> markArrived(String shareId);

  /// Revoke a share immediately (stop resolving the link, drop server state).
  Future<void> revoke(String shareId);
}

/// The READ side of the contract (the follower / "Friends' rides" surface).
///
/// Kept SEPARATE from [ShareBackend] on purpose: the push-only implementers
/// (Noop, tests) stay untouched, and only a backend that can serve reads
/// (HttpShareBackend) implements it. This is the one backend addition the
/// follower needs on top of the push contract:
///
///   GET {base}/v1/share/{id}/status -> 200 {id, status, destLabel, etaEpochMs,
///                                             lat, lng, atMs}   (latest only)
///                                       410 Gone   (expired / revoked)
///                                       404        (unknown id)
///
/// The response is the LATEST coarse snapshot plus share metadata — never a
/// trajectory. All errors are swallowed and surface as `null`.
abstract class ShareStatusReader {
  /// Fetch the latest coarse status for [id], or null if unavailable/unknown.
  /// A 410 returns a [ShareStatusView.gone] so the follower can retire the row.
  Future<ShareStatusView?> getStatus(String id);
}

/// DEFAULT backend. Everything is a no-op; basic share works fully offline.
class NoopShareBackend implements ShareBackend {
  const NoopShareBackend();

  @override
  bool get supportsLive => false;

  @override
  Future<String?> createShare(ShareSession session) async => null;

  @override
  Future<void> pushLocation(String shareId, ShareSnapshot snapshot) async {}

  @override
  Future<void> markArrived(String shareId) async {}

  @override
  Future<void> revoke(String shareId) async {}
}

/// Skeleton HTTP backend for the founder's Railway server. Enabled only when a
/// [baseUrl] is supplied; still fail-safe (all transport errors swallowed).
///
/// Contract (see docs/share/BACKEND_CONTRACT.md):
///   POST   {base}/v1/share            {id, mode, destLabel, etaEpochMs, expiresAtMs} -> {serverId}
///   POST   {base}/v1/share/{id}/ping  {lat, lng, etaEpochMs, atMs}                   -> 204
///   POST   {base}/v1/share/{id}/arrived                                              -> 204
///   DELETE {base}/v1/share/{id}                                                       -> 204
/// Auth: a founder-provisioned bearer token ([authToken]); the server enforces
/// TTL + hard-delete and never persists a trajectory.
class HttpShareBackend implements ShareBackend, ShareStatusReader {
  final String baseUrl;
  final String? authToken;
  final http.Client _client;
  final Duration timeout;

  HttpShareBackend({
    required this.baseUrl,
    this.authToken,
    http.Client? client,
    this.timeout = const Duration(seconds: 8),
  }) : _client = client ?? http.Client();

  @override
  bool get supportsLive => true;

  Map<String, String> get _headers => {
        'content-type': 'application/json',
        if (authToken != null) 'authorization': 'Bearer $authToken',
      };

  String get _base =>
      baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;

  /// Sanitize a share id for use in a URL path segment. Prevents path
  /// traversal (e.g. `../../admin`) from a malicious deep link.
  String _safeId(String id) => Uri.encodeComponent(id.trim());

  @override
  Future<String?> createShare(ShareSession session) async {
    try {
      final res = await _client
          .post(
            Uri.parse('$_base/v1/share'),
            headers: _headers,
            body: jsonEncode({
              'id': session.id,
              'mode': session.mode.name,
              'destLabel': session.destLabel,
              'etaEpochMs': session.etaEpochMs,
              'expiresAtMs': session.expiresAtMs,
            }),
          )
          .timeout(timeout);
      if (res.statusCode ~/ 100 != 2) return null;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      return body['serverId'] as String?;
    } catch (_) {
      return null; // fail-safe: client falls back to its own id
    }
  }

  @override
  Future<void> pushLocation(String shareId, ShareSnapshot snapshot) async {
    try {
      await _client
          .post(
            Uri.parse('$_base/v1/share/${_safeId(shareId)}/ping'),
            headers: _headers,
            body: jsonEncode(snapshot.toJson()),
          )
          .timeout(timeout);
    } catch (_) {/* best effort */}
  }

  @override
  Future<void> markArrived(String shareId) async {
    try {
      await _client
          .post(Uri.parse('$_base/v1/share/${_safeId(shareId)}/arrived'),
              headers: _headers)
          .timeout(timeout);
    } catch (_) {/* best effort */}
  }

  @override
  Future<void> revoke(String shareId) async {
    try {
      await _client
          .delete(Uri.parse('$_base/v1/share/${_safeId(shareId)}'), headers: _headers)
          .timeout(timeout);
    } catch (_) {/* best effort */}
  }

  /// READ side (follower). Backend addition: GET {base}/v1/share/{id}/status.
  /// 410 -> a gone view; 404 / non-2xx / transport error -> null (fail-safe).
  @override
  Future<ShareStatusView?> getStatus(String id) async {
    try {
      final res = await _client
          .get(Uri.parse('$_base/v1/share/${_safeId(id)}/status'), headers: _headers)
          .timeout(timeout);
      if (res.statusCode == 410) return ShareStatusView.gone(id);
      if (res.statusCode == 404) return null;
      if (res.statusCode ~/ 100 != 2) return null;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      return ShareStatusView.fromJson(id, body);
    } catch (_) {
      return null; // fail-safe: follower keeps its last-known view
    }
  }
}
