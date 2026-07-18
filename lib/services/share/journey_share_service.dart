// lib/services/share/journey_share_service.dart
//
// FREE, viral journey sharing — the organic growth loop. Building a share link /
// message and starting a basic share carries NO entitlement check ANYWHERE
// (test-enforced): a share must always be one tap, for every user.
//
// This service only READS: it never touches the arm → track → alarm spine, and
// every method is fail-safe (swallows its own errors, returns a safe default) so
// a share failure can never block the app or the alarm.
//
// PRIVACY: pings carry only the latest coarse point (5 dp) at a ≥15 s throttle
// (matching EtaEngine._saveThrottle); there is no trajectory buffer. With the
// default NoopShareBackend nothing leaves the device at all.

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'journey_share_models.dart';
import 'live_share_backend.dart';
import 'share_link_builder.dart';

/// The result of starting a share — the session plus the ready-to-send text.
class StartedShare {
  final ShareSession session;
  final String url;
  final String message;
  const StartedShare(
      {required this.session, required this.url, required this.message});
}

class JourneyShareService {
  JourneyShareService._({int Function()? nowMs})
      : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// Process-wide singleton (wall clock).
  static final JourneyShareService instance = JourneyShareService._();

  /// Test factory with an injectable clock.
  factory JourneyShareService.forTest({int Function()? nowMs}) =>
      JourneyShareService._(nowMs: nowMs);

  static const String boxName = 'gw_share_sessions';
  static const String _secretKey = 'gw_share_secret';

  /// Ping throttle — matches EtaEngine._saveThrottle so we never out-run the
  /// tracking cadence.
  static const Duration pingThrottle = Duration(seconds: 15);

  /// A basic share auto-expires after this if never explicitly ended.
  static const Duration defaultTtl = Duration(hours: 6);

  final Uuid _uuid = const Uuid();

  /// Pluggable transport. Defaults to fully-offline Noop; the app may inject a
  /// live backend at startup without changing any call site.
  ShareBackend backend = const NoopShareBackend();

  /// App-Links domain used to build recipient URLs (founder-configurable).
  String domain = ShareLinkBuilder.defaultDomain;

  /// True whenever there is at least one active (en-route) share. UI binds a
  /// "You're sharing" banner to this.
  final ValueNotifier<bool> isSharing = ValueNotifier<bool>(false);

  // Injected clock (tests).
  final int Function() _nowMs;

  Box<String>? _box;
  Future<void>? _opening;

  String? _cachedSecret;
  int _lastPingMs = 0;
  StreamSubscription<dynamic>? _trackingSub;

  int _now() => _nowMs();

  // ---------------------------------------------------------------------------
  // Box lifecycle (self-healing — mirrors RouteMemoryService).
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
        dev.log('share box open failed: $e — recreating',
            name: 'JourneyShareService');
        try {
          await Hive.deleteBoxFromDisk(boxName);
          _box = await Hive.openBox<String>(boxName);
        } catch (e2) {
          dev.log('share box recreate failed: $e2',
              name: 'JourneyShareService');
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
  // Secret (HMAC key) — generated once, stored locally.
  // ---------------------------------------------------------------------------

  Future<String> _secret() async {
    if (_cachedSecret != null) return _cachedSecret!;
    try {
      final prefs = await SharedPreferences.getInstance();
      var s = prefs.getString(_secretKey);
      if (s == null || s.isEmpty) {
        s = _randomSecret();
        await prefs.setString(_secretKey, s);
      }
      _cachedSecret = s;
      return s;
    } catch (_) {
      // Ephemeral fallback: still lets us mint a token this session.
      return _cachedSecret ??= _randomSecret();
    }
  }

  String _randomSecret() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(32, (_) => rnd.nextInt(256));
    return base64Url.encode(bytes);
  }

  // ---------------------------------------------------------------------------
  // Start / stop shares
  // ---------------------------------------------------------------------------

  /// Start a share and return the ready-to-send message + URL.
  ///
  /// **No entitlement read here** — basic share is always free. [mode] lets the
  /// Guardian layer request a live/guardian session through the SAME code path
  /// (its own Pro check lives in GuardianService), but the default is a basic
  /// FREE link.
  Future<StartedShare> startBasicShare({
    String? destLabel,
    DateTime? eta,
    ShareMode mode = ShareMode.basicLink,
    Duration? ttl,
  }) async {
    final now = _now();
    final id = _uuid.v4();
    final session = ShareSession(
      id: id,
      mode: mode,
      status: ShareStatus.enRoute,
      createdAtMs: now,
      expiresAtMs: now + (ttl ?? defaultTtl).inMilliseconds,
      destLabel: destLabel,
      etaEpochMs: eta?.millisecondsSinceEpoch,
    );

    await _put(session);

    // Best-effort backend registration (Noop returns null → we keep our id).
    String? backendId;
    try {
      backendId = await backend.createShare(session);
    } catch (_) {/* offline is fine */}
    if (backendId != null && backendId.isNotEmpty) {
      await _put(session.copyWith(backendId: backendId));
    }

    _refreshSharingFlag();

    final secret = await _secret();
    final token = ShareLinkBuilder.mintToken(id, secret);
    final url = ShareLinkBuilder.buildShareUrl(id, domain: domain, token: token);
    final message = ShareLinkBuilder.buildBasicMessage(
        url: url, eta: eta, destLabel: destLabel);
    return StartedShare(session: session, url: url, message: message);
  }

  /// Rebuild the share text for an existing session (e.g. re-share button).
  Future<StartedShare?> messageFor(String id) async {
    final s = await _get(id);
    if (s == null) return null;
    final secret = await _secret();
    final token = ShareLinkBuilder.mintToken(id, secret);
    final url = ShareLinkBuilder.buildShareUrl(id, domain: domain, token: token);
    final message = ShareLinkBuilder.buildBasicMessage(
      url: url,
      destLabel: s.destLabel,
      eta: s.etaEpochMs != null
          ? DateTime.fromMillisecondsSinceEpoch(s.etaEpochMs!)
          : null,
    );
    return StartedShare(session: s, url: url, message: message);
  }

  /// Push the latest coarse position to any active live session. Throttled to
  /// [pingThrottle]; a no-op when the backend can't carry live updates. Never
  /// throws.
  Future<void> ingestLocation(double lat, double lng, {DateTime? eta}) async {
    try {
      if (!backend.supportsLive) return;
      final now = _now();
      if (now - _lastPingMs < pingThrottle.inMilliseconds) return;
      final active = await _activeSessions();
      if (active.isEmpty) return;
      _lastPingMs = now;
      final snap = ShareSnapshot(
        lat: lat,
        lng: lng,
        atMs: now,
        etaEpochMs: eta?.millisecondsSinceEpoch,
      );
      for (final s in active) {
        // Fire-and-forget per session; a slow endpoint never stalls tracking.
        unawaited(backend.pushLocation(s.backendId ?? s.id, snap));
      }
    } catch (e) {
      dev.log('ingestLocation ignored: $e', name: 'JourneyShareService');
    }
  }

  /// Convenience: bind a position stream (e.g. ActiveRouteManager.stateStream)
  /// so pings flow automatically. [latOf]/[lngOf] extract coords from an event.
  /// Kept generic so the service never imports the tracking layer.
  void bindTracking<T>(
    Stream<T> positions, {
    required double Function(T) latOf,
    required double Function(T) lngOf,
    DateTime? Function()? etaProvider,
  }) {
    _trackingSub?.cancel();
    _trackingSub = positions.listen((e) {
      try {
        ingestLocation(latOf(e), lngOf(e), eta: etaProvider?.call());
      } catch (_) {/* never break tracking */}
    }, onError: (_) {});
  }

  Future<void> unbindTracking() async {
    await _trackingSub?.cancel();
    _trackingSub = null;
  }

  /// Mark all active sessions arrived (called from the post-alarm path via
  /// Guardian, or from the post-arrival share row). Idempotent, never throws.
  Future<void> markArrived() async {
    try {
      final active = await _activeSessions();
      for (final s in active) {
        await _put(s.copyWith(status: ShareStatus.arrived));
        unawaited(backend.markArrived(s.backendId ?? s.id));
      }
      _refreshSharingFlag();
    } catch (e) {
      dev.log('markArrived ignored: $e', name: 'JourneyShareService');
    }
  }

  /// Revoke a single share.
  Future<void> revoke(String id) async {
    try {
      final s = await _get(id);
      if (s == null) return;
      await _put(s.copyWith(status: ShareStatus.revoked));
      unawaited(backend.revoke(s.backendId ?? s.id));
      _refreshSharingFlag();
    } catch (e) {
      dev.log('revoke ignored: $e', name: 'JourneyShareService');
    }
  }

  /// Revoke every active share (e.g. tapping the "You're sharing" banner).
  Future<void> revokeAll() async {
    try {
      for (final s in await _activeSessions()) {
        await _put(s.copyWith(status: ShareStatus.revoked));
        unawaited(backend.revoke(s.backendId ?? s.id));
      }
      _refreshSharingFlag();
    } catch (e) {
      dev.log('revokeAll ignored: $e', name: 'JourneyShareService');
    }
  }

  /// All sessions the user has started (newest first), sweeping expiries.
  Future<List<ShareSession>> allSessions() async {
    await _sweepExpired();
    final box = await _ensureBox();
    if (box == null) return const [];
    final out = <ShareSession>[];
    for (final v in box.values) {
      try {
        out.add(ShareSession.decode(v));
      } catch (_) {/* skip corrupt entry */}
    }
    out.sort((a, b) => b.createdAtMs.compareTo(a.createdAtMs));
    return out;
  }

  // ---------------------------------------------------------------------------
  // internals
  // ---------------------------------------------------------------------------

  Future<List<ShareSession>> _activeSessions() async {
    await _sweepExpired();
    final all = await allSessions();
    return all.where((s) => s.isActive).toList();
  }

  Future<void> _sweepExpired() async {
    final box = await _ensureBox();
    if (box == null) return;
    final now = _now();
    for (final key in box.keys.toList()) {
      final raw = box.get(key);
      if (raw == null) continue;
      try {
        final s = ShareSession.decode(raw);
        if (s.isActive && s.isExpiredAt(now)) {
          await box.put(key, s.copyWith(status: ShareStatus.expired).encode());
        }
      } catch (_) {
        await box.delete(key); // drop unparseable entry
      }
    }
  }

  Future<void> _put(ShareSession s) async {
    final box = await _ensureBox();
    await box?.put(s.id, s.encode());
  }

  Future<ShareSession?> _get(String id) async {
    final box = await _ensureBox();
    final raw = box?.get(id);
    if (raw == null) return null;
    try {
      return ShareSession.decode(raw);
    } catch (_) {
      return null;
    }
  }

  void _refreshSharingFlag() {
    // Recompute asynchronously; the notifier is advisory UI state.
    _activeSessions().then((a) {
      isSharing.value = a.isNotEmpty;
    }).catchError((_) {
      isSharing.value = false;
    });
  }
}
