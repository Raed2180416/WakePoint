// lib/services/share/followed_rides_service.dart
//
// "Friends' rides" — the FOLLOWER side of GeoWake journey sharing. Additive and
// completely separate from the arm → track → alarm spine: this service only
// READS a friend's coarse status from the backend and never influences the
// user's own alarm, tracking, or entitlement in any way.
//
// PRIVACY BY CONSTRUCTION:
//   • The user follows opaque share ids. Only the id (+ optional HMAC token) is
//     PERSISTED locally — the coarse coordinates that arrive in a ShareStatusView
//     are held in memory only and are NEVER written to disk.
//   • The follower surface renders ROUTE-RELATIVE / time-relative copy only
//     ("On the way to X — arriving ~8:42", "N min away", "Arrived safely",
//     "Link expired"). Raw lat/lng is NEVER shown to the user.
//   • Everything is fail-safe: a poll failure keeps the last-known view and can
//     never throw into the UI or the app.

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'journey_share_models.dart';
import 'live_share_backend.dart';
import 'share_link_builder.dart';

/// One ride the user is following: the persisted subscription (id/token/when)
/// plus the LATEST in-memory coarse view (never persisted) and last poll error.
@immutable
class FollowedRide {
  /// The opaque share id (the `/j/{id}` slug).
  final String id;

  /// Optional HMAC token captured from the link (`?t=`), passed to reads so a
  /// token-gated backend can verify the follower holds a genuine link.
  final String? token;

  /// When the user started following (epoch ms) — for stable newest-first order.
  final int addedAtMs;

  /// Latest coarse status. IN-MEMORY ONLY, never persisted. Null until polled.
  final ShareStatusView? latest;

  /// Last poll error, if the most recent refresh failed (kept for a subtle
  /// "reconnecting…" hint; the last-known [latest] is preserved regardless).
  final Object? error;

  const FollowedRide({
    required this.id,
    required this.addedAtMs,
    this.token,
    this.latest,
    this.error,
  });

  FollowedRide copyWith({
    ShareStatusView? latest,
    Object? error,
    bool clearError = false,
  }) =>
      FollowedRide(
        id: id,
        token: token,
        addedAtMs: addedAtMs,
        latest: latest ?? this.latest,
        error: clearError ? null : (error ?? this.error),
      );

  /// The ONLY thing that touches disk — id/token/addedAt. No coordinates.
  Map<String, dynamic> toRecordJson() => {
        'id': id,
        'token': token,
        'addedAtMs': addedAtMs,
      };

  factory FollowedRide.fromRecordJson(Map<String, dynamic> j) => FollowedRide(
        id: j['id'] as String,
        token: j['token'] as String?,
        addedAtMs: (j['addedAtMs'] as num?)?.toInt() ?? 0,
      );

  String encodeRecord() => jsonEncode(toRecordJson());

  static FollowedRide decodeRecord(String s) =>
      FollowedRide.fromRecordJson(jsonDecode(s) as Map<String, dynamic>);
}

/// PURE, coarse, route-relative formatting of a followed ride. No coordinates
/// ever reach these strings — kept static + pure so it is exhaustively testable.
class FollowedRideFormat {
  const FollowedRideFormat._();

  /// The primary line, e.g.:
  ///   "On the way to MG Road — arriving ~8:42"
  ///   "On the way"                       (no dest / eta yet)
  ///   "Arrived safely at MG Road"
  ///   "Link expired" / "Sharing stopped"
  ///   "Waiting for updates…"             (followed but not yet polled)
  static String headline(FollowedRide r) {
    final v = r.latest;
    if (v == null) return 'Waiting for updates…';
    if (v.gone || v.status == ShareStatus.expired) return 'Link expired';
    if (v.status == ShareStatus.revoked) return 'Sharing stopped';
    if (v.status == ShareStatus.arrived) {
      final where = _dest(v.destLabel);
      return 'Arrived safely${where == null ? '' : ' at $where'}';
    }
    // enRoute
    final dest = _dest(v.destLabel);
    final eta = v.etaEpochMs;
    final arriving =
        eta != null ? ' — arriving ~${ShareLinkBuilder.formatEta(DateTime.fromMillisecondsSinceEpoch(eta))}' : '';
    if (dest != null) return 'On the way to $dest$arriving';
    if (arriving.isNotEmpty) return 'On the way$arriving';
    return 'On the way';
  }

  /// A short time-relative sub-line, e.g. "8 min away" / "Arriving now", or null
  /// when there is no active ETA to derive it from.
  static String? minutesAway(FollowedRide r, {required int nowMs}) {
    final v = r.latest;
    if (v == null || !v.isActive) return null;
    final eta = v.etaEpochMs;
    if (eta == null) return null;
    final mins = ((eta - nowMs) / 60000).round();
    if (mins <= 0) return 'Arriving now';
    if (mins == 1) return '1 min away';
    return '$mins min away';
  }

  static String? _dest(String? label) {
    final t = label?.trim();
    return (t == null || t.isEmpty) ? null : t;
  }
}

/// Subscribes to a set of followed share ids and keeps their latest coarse
/// status live via polling. Exposes a [ValueListenable] the UI binds to.
class FollowedRidesService {
  FollowedRidesService._({
    int Function()? nowMs,
    Box<String>? box,
  })  : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch),
        _box = box;

  /// Process-wide singleton (wall clock).
  static final FollowedRidesService instance = FollowedRidesService._();

  /// Test factory: injectable clock and (optionally) a pre-opened box.
  factory FollowedRidesService.forTest({
    int Function()? nowMs,
    Box<String>? box,
  }) =>
      FollowedRidesService._(nowMs: nowMs, box: box);

  static const String boxName = 'gw_followed_rides';

  /// How often the follower re-reads each ride's status while polling.
  static const Duration pollInterval = Duration(seconds: 20);

  final int Function() _nowMs;

  /// The live list of followed rides, newest-first. UI binds to this.
  final ValueNotifier<List<FollowedRide>> rides =
      ValueNotifier<List<FollowedRide>>(const []);

  /// Backend read surface. Null when no live backend is configured (offline):
  /// rides can still be followed/persisted; they just show "Waiting…".
  ShareStatusReader? _reader;

  final Map<String, FollowedRide> _byId = {};
  Box<String>? _box;
  Future<void>? _opening;
  Timer? _timer;
  bool _loaded = false;

  int _now() => _nowMs();

  /// Wire the read backend (e.g. the configured HttpShareBackend). Safe to call
  /// with null (offline). Does not start polling by itself.
  void attachReader(ShareStatusReader? reader) {
    _reader = reader;
  }

  // ---------------------------------------------------------------------------
  // Box lifecycle (self-healing — mirrors JourneyShareService).
  // ---------------------------------------------------------------------------

  Future<Box<String>?> _ensureBox() async {
    if (_box != null && _box!.isOpen) return _box;
    if (_opening != null) {
      await _opening;
      return _box;
    }
    _opening = () async {
      try {
        _box = await Hive.openBox<String>(boxName);
      } catch (e) {
        dev.log('followed box open failed: $e — recreating',
            name: 'FollowedRidesService');
        try {
          await Hive.deleteBoxFromDisk(boxName);
          _box = await Hive.openBox<String>(boxName);
        } catch (e2) {
          dev.log('followed box recreate failed: $e2',
              name: 'FollowedRidesService');
        }
      }
    }();
    try {
      await _opening;
    } finally {
      _opening = null;
    }
    return _box;
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Load persisted subscriptions into memory and (if [autoPoll]) begin polling.
  /// Idempotent; safe to call from app init. Never throws.
  Future<void> init({bool autoPoll = true}) async {
    try {
      await _load();
      if (autoPoll) startPolling();
    } catch (e) {
      dev.log('init ignored: $e', name: 'FollowedRidesService');
    }
  }

  Future<void> _load() async {
    if (_loaded) return;
    final box = await _ensureBox();
    if (box == null) return;
    for (final v in box.values) {
      try {
        final r = FollowedRide.decodeRecord(v);
        _byId[r.id] = r;
      } catch (_) {/* skip corrupt entry */}
    }
    _loaded = true;
    _publish();
  }

  /// True if the user already follows [id].
  bool isFollowing(String id) => _byId.containsKey(id);

  /// Start following [id] (idempotent) and immediately fetch its status. Returns
  /// the resulting row. Never throws.
  Future<FollowedRide> follow(String id, {String? token}) async {
    final trimmed = id.trim();
    final existing = _byId[trimmed];
    final ride = existing ??
        FollowedRide(id: trimmed, token: token, addedAtMs: _now());
    // Adopt a freshly-supplied token if the previous follow had none.
    final merged = (existing != null && token != null && existing.token == null)
        ? FollowedRide(
            id: ride.id,
            token: token,
            addedAtMs: ride.addedAtMs,
            latest: ride.latest,
            error: ride.error)
        : ride;
    _byId[trimmed] = merged;
    await _persist(merged);
    _publish();
    startPolling();
    unawaited(refreshOne(trimmed));
    return merged;
  }

  /// Stop following [id] — removes the local subscription only (this is a READ
  /// surface; nothing is sent to the backend). Never throws.
  Future<void> unfollow(String id) async {
    _byId.remove(id);
    try {
      final box = await _ensureBox();
      await box?.delete(id);
    } catch (e) {
      dev.log('unfollow persist ignored: $e', name: 'FollowedRidesService');
    }
    _publish();
    if (_byId.isEmpty) stopPolling();
  }

  /// Re-read every followed ride's status once. Fail-safe per ride.
  Future<void> refreshAll() async {
    final ids = _byId.keys.toList();
    for (final id in ids) {
      await refreshOne(id);
    }
  }

  /// Re-read a single ride. On success updates the view; on any failure keeps
  /// the last-known view and records the error. Never throws.
  Future<void> refreshOne(String id) async {
    final current = _byId[id];
    if (current == null) return;
    final reader = _reader;
    if (reader == null) return; // offline: leave "Waiting…"
    try {
      final view = await reader.getStatus(id);
      final now = _byId[id];
      if (now == null) return; // unfollowed mid-flight
      if (view == null) {
        _byId[id] = now.copyWith(error: 'unreachable');
      } else {
        _byId[id] = now.copyWith(latest: view, clearError: true);
      }
      _publish();
    } catch (e) {
      final now = _byId[id];
      if (now != null) {
        _byId[id] = now.copyWith(error: e);
        _publish();
      }
      dev.log('refreshOne($id) ignored: $e', name: 'FollowedRidesService');
    }
  }

  /// Begin periodic polling (no-op if already running or nothing to poll).
  void startPolling() {
    if (_timer != null) return;
    if (_byId.isEmpty) return;
    unawaited(refreshAll());
    _timer = Timer.periodic(pollInterval, (_) => unawaited(refreshAll()));
  }

  void stopPolling() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() {
    stopPolling();
  }

  // ---------------------------------------------------------------------------
  // internals
  // ---------------------------------------------------------------------------

  Future<void> _persist(FollowedRide r) async {
    try {
      final box = await _ensureBox();
      await box?.put(r.id, r.encodeRecord());
    } catch (e) {
      dev.log('persist ignored: $e', name: 'FollowedRidesService');
    }
  }

  void _publish() {
    final list = _byId.values.toList()
      ..sort((a, b) => b.addedAtMs.compareTo(a.addedAtMs));
    rides.value = List.unmodifiable(list);
  }
}
