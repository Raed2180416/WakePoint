// lib/services/share/journey_share_models.dart
//
// Pure, dependency-light data types for GeoWake journey sharing.
//
// PRIVACY BY CONSTRUCTION:
//   • A ShareSnapshot carries ONLY the latest coarse position (lat/lng rounded
//     to 5 decimal places) + an optional ETA — there is deliberately NO history
//     / trajectory array (a test enforces the absence of any such field).
//   • Coordinates never leave the device except through the pluggable
//     ShareBackend, and the default backend (NoopShareBackend) is offline.
//
// Every user-facing string produced from these lives in share_link_builder and
// says "GeoWake".

import 'dart:convert';

/// How a share is being conducted.
enum ShareMode {
  /// A one-off "track my journey" link/message. FREE, no live pings.
  basicLink,

  /// Live coarse-position updates to a recipient page. Needs a live backend.
  live,

  /// Guardian: auto-shared to a saved contact + "arrived safely" on wake. PRO.
  guardian,
}

/// Lifecycle of a share session.
enum ShareStatus { enRoute, arrived, revoked, expired }

ShareMode _modeFromName(String? s) => ShareMode.values.firstWhere(
      (m) => m.name == s,
      orElse: () => ShareMode.basicLink,
    );

ShareStatus _statusFromName(String? s) => ShareStatus.values.firstWhere(
      (m) => m.name == s,
      orElse: () => ShareStatus.enRoute,
    );

/// A single share the user has started. Persisted locally (Hive) as JSON.
class ShareSession {
  /// Client-generated, opaque, URL-safe id (uuid v4). Also the `/j/{id}` slug.
  final String id;

  /// Optional server-side id, set once a live backend accepts [createShare].
  final String? backendId;

  final ShareMode mode;
  final ShareStatus status;

  /// Coarse human label for the destination (station/area name). Never coords.
  final String? destLabel;

  /// Best-known ETA at share time (epoch ms), for the "arriving ~hh:mm" copy.
  final int? etaEpochMs;

  final int createdAtMs;

  /// Hard expiry (epoch ms). After this the session self-expires and the link
  /// stops resolving; the backend is expected to TTL-delete server state.
  final int expiresAtMs;

  const ShareSession({
    required this.id,
    required this.mode,
    required this.status,
    required this.createdAtMs,
    required this.expiresAtMs,
    this.backendId,
    this.destLabel,
    this.etaEpochMs,
  });

  bool isExpiredAt(int nowMs) => nowMs >= expiresAtMs;

  bool get isActive =>
      status == ShareStatus.enRoute; // arrived/revoked/expired are terminal

  ShareSession copyWith({
    String? backendId,
    ShareStatus? status,
    int? etaEpochMs,
  }) =>
      ShareSession(
        id: id,
        mode: mode,
        status: status ?? this.status,
        createdAtMs: createdAtMs,
        expiresAtMs: expiresAtMs,
        backendId: backendId ?? this.backendId,
        destLabel: destLabel,
        etaEpochMs: etaEpochMs ?? this.etaEpochMs,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'backendId': backendId,
        'mode': mode.name,
        'status': status.name,
        'destLabel': destLabel,
        'etaEpochMs': etaEpochMs,
        'createdAtMs': createdAtMs,
        'expiresAtMs': expiresAtMs,
      };

  factory ShareSession.fromJson(Map<String, dynamic> j) => ShareSession(
        id: j['id'] as String,
        backendId: j['backendId'] as String?,
        mode: _modeFromName(j['mode'] as String?),
        status: _statusFromName(j['status'] as String?),
        destLabel: j['destLabel'] as String?,
        etaEpochMs: (j['etaEpochMs'] as num?)?.toInt(),
        createdAtMs: (j['createdAtMs'] as num).toInt(),
        expiresAtMs: (j['expiresAtMs'] as num).toInt(),
      );

  String encode() => jsonEncode(toJson());

  static ShareSession decode(String s) =>
      ShareSession.fromJson(jsonDecode(s) as Map<String, dynamic>);
}

/// The ONLY position payload that ever leaves the device — the latest coarse
/// point. NO trajectory / history array by design (enforced by test).
class ShareSnapshot {
  /// Latitude rounded to 5 dp (~1.1 m) — coarse, non-identifying.
  final double lat;

  /// Longitude rounded to 5 dp.
  final double lng;

  /// Optional current ETA (epoch ms).
  final int? etaEpochMs;

  /// When this snapshot was taken (epoch ms).
  final int atMs;

  ShareSnapshot({
    required double lat,
    required double lng,
    required this.atMs,
    this.etaEpochMs,
  })  : lat = _round5(lat),
        lng = _round5(lng);

  static double _round5(double v) => (v * 1e5).roundToDouble() / 1e5;

  Map<String, dynamic> toJson() => {
        'lat': lat,
        'lng': lng,
        'etaEpochMs': etaEpochMs,
        'atMs': atMs,
      };
}

/// The READ view a follower gets back from the backend for a share id
/// (`GET /v1/share/{id}/status`). It is the latest coarse snapshot plus the
/// small amount of share metadata a follower needs to render a ROUTE-RELATIVE
/// status ("On the way to X — arriving ~8:42").
///
/// PRIVACY: [lat]/[lng] are coarse (5 dp) and are NEVER rendered to the user;
/// the follower surface derives only route-relative / time-relative copy from
/// [destLabel] + [etaEpochMs] + [status]. The follower never persists this view.
class ShareStatusView {
  /// The share id this view describes.
  final String id;

  /// Lifecycle status the server reports (enRoute / arrived; expired / revoked
  /// arrive as [gone]).
  final ShareStatus status;

  /// Coarse destination label (station / area), never coordinates.
  final String? destLabel;

  /// Latest known ETA (epoch ms).
  final int? etaEpochMs;

  /// Coarse latest point (5 dp). DELIVERY-INTERNAL ONLY — never shown raw.
  final double? lat;

  /// Coarse latest point (5 dp). DELIVERY-INTERNAL ONLY — never shown raw.
  final double? lng;

  /// When the latest snapshot was taken (epoch ms), for a "updated N min ago".
  final int? atMs;

  /// True when the server returned 410 Gone — the share expired/was revoked and
  /// all state hard-deleted. The follower shows "Link expired" and stops polling.
  final bool gone;

  const ShareStatusView({
    required this.id,
    required this.status,
    this.destLabel,
    this.etaEpochMs,
    this.lat,
    this.lng,
    this.atMs,
    this.gone = false,
  });

  /// A terminal "gone" view (410 / expired / revoked) — no coordinates.
  factory ShareStatusView.gone(String id) =>
      ShareStatusView(id: id, status: ShareStatus.expired, gone: true);

  factory ShareStatusView.fromJson(String id, Map<String, dynamic> j) =>
      ShareStatusView(
        id: (j['id'] as String?) ?? id,
        status: _statusFromName(j['status'] as String?),
        destLabel: j['destLabel'] as String?,
        etaEpochMs: (j['etaEpochMs'] as num?)?.toInt(),
        lat: (j['lat'] as num?)?.toDouble(),
        lng: (j['lng'] as num?)?.toDouble(),
        atMs: (j['atMs'] as num?)?.toInt(),
        gone: (j['gone'] as bool?) ?? false,
      );

  /// True while the ride is still in progress (worth continued polling).
  bool get isActive => !gone && status == ShareStatus.enRoute;
}

/// A recipient the user has chosen for Guardian mode. Stored LOCALLY only.
enum GuardianChannel { app, whatsapp, sms }

GuardianChannel _channelFromName(String? s) => GuardianChannel.values.firstWhere(
      (m) => m.name == s,
      orElse: () => GuardianChannel.sms,
    );

class GuardianContact {
  final String id;
  final String displayName;
  final GuardianChannel channel;

  /// Delivery address for the channel: a phone number (sms/whatsapp) or an
  /// in-app user token (app). Stored locally, never aggregated.
  final String address;

  const GuardianContact({
    required this.id,
    required this.displayName,
    required this.channel,
    required this.address,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'displayName': displayName,
        'channel': channel.name,
        'address': address,
      };

  factory GuardianContact.fromJson(Map<String, dynamic> j) => GuardianContact(
        id: j['id'] as String,
        displayName: j['displayName'] as String? ?? '',
        channel: _channelFromName(j['channel'] as String?),
        address: j['address'] as String? ?? '',
      );

  String encode() => jsonEncode(toJson());

  static GuardianContact decode(String s) =>
      GuardianContact.fromJson(jsonDecode(s) as Map<String, dynamic>);
}
