// lib/services/data_asset/mobility_consent_service.dart
//
// GeoWake — DPDP Rule-3 consent for the opt-in mobility data surface
// (DATA_SURFACE_SPEC §2.10).
//
// Design mirrors PremiumService: pure + dependency-injected (load/save default
// to in-memory), so it is deterministically unit-testable with no device.
//
// Persistence key `gw_mobility_consent_v1` is SEPARATE from the entitlement blob
// (`geowake_entitlement_v1`) and from any telemetry key — one consent, one key.
//
// Guarantees enforced here:
//   • Default OFF. isSharingEnabled is FALSE until an explicit, versioned grant.
//   • Fail-safe parse. A missing/corrupt blob resolves to DISABLED, never ON.
//   • Material-change re-consent. A stored noticeVersion that differs from the
//     current [kConsentNoticeVersion] is treated as NOT consented (forces a fresh
//     grant against the new notice).
//   • One-tap withdrawal (DPDP s.6(4)–(6)) that also triggers erasure of on-device
//     aggregate state (s.8(7)/s.12) via the injected [onWithdraw] callback.

import 'dart:convert';
import 'dart:developer' as dev;

import 'data_asset_config.dart';

class MobilityConsentService {
  /// SharedPreferences key — deliberately distinct from every other consent/
  /// entitlement/telemetry key.
  static const String persistKey = 'gw_mobility_consent_v1';

  final int Function() _nowMs;
  late final Future<String?> Function(String key) _load;
  late final Future<void> Function(String key, String value) _save;

  // In-memory state (hydrated by [load]).
  bool _enabled = false;
  String _noticeVersion = '';
  int _grantedAtMs = 0;
  int _withdrawnAtMs = 0;

  /// Optional hook run inside [withdraw] to erase on-device aggregate state and
  /// append the auditable erasure record. Wired by DataAssetPipeline to
  /// `OdAggregator.wipeAndLogErasure`. Failure here never blocks withdrawal.
  Future<void> Function()? onWithdraw;

  MobilityConsentService({
    Future<String?> Function(String key)? load,
    Future<void> Function(String key, String value)? save,
    int Function()? nowMs,
    this.onWithdraw,
  }) : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch) {
    if (load != null && save != null) {
      _load = load;
      _save = save;
    } else {
      final mem = <String, String>{};
      _load = load ?? ((k) async => mem[k]);
      _save = save ?? ((k, v) async => mem[k] = v);
    }
  }

  /// Hydrate persisted consent. Fail-safe: any failure or malformed blob leaves
  /// the user DISABLED.
  Future<void> load() async {
    try {
      final raw = await _load(persistKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final enabled = decoded['enabled'];
      final version = decoded['noticeVersion'];
      // Only a strict boolean true counts as enabled.
      _enabled = enabled == true;
      _noticeVersion = version is String ? version : '';
      final g = decoded['grantedAtMs'];
      final w = decoded['withdrawnAtMs'];
      _grantedAtMs = g is int ? g : 0;
      _withdrawnAtMs = w is int ? w : 0;
    } catch (e) {
      // Any parse failure ⇒ treat as DISABLED (fail-safe).
      _enabled = false;
      _noticeVersion = '';
      _grantedAtMs = 0;
      _withdrawnAtMs = 0;
      dev.log('consent load failed; defaulting DISABLED: $e',
          name: 'MobilityConsentService');
    }
  }

  Future<void> _persist() async {
    try {
      await _save(
        persistKey,
        jsonEncode({
          'enabled': _enabled,
          'noticeVersion': _noticeVersion,
          'grantedAtMs': _grantedAtMs,
          'withdrawnAtMs': _withdrawnAtMs,
        }),
      );
    } catch (e) {
      dev.log('consent persist failed: $e', name: 'MobilityConsentService');
    }
  }

  /// THE runtime egress gate. True only when the user granted consent AND that
  /// grant was against the CURRENT notice version (a bump forces re-consent).
  bool get isSharingEnabled =>
      _enabled && _noticeVersion == kConsentNoticeVersion;

  /// The raw stored flag (before the notice-version check) — for UI that wants to
  /// show "consent needs refreshing" after a notice bump.
  bool get rawEnabledFlag => _enabled;

  String get noticeVersion => _noticeVersion;
  int get grantedAtMs => _grantedAtMs;
  int get withdrawnAtMs => _withdrawnAtMs;

  /// Record an explicit, informed grant against the current notice version.
  Future<void> grant() async {
    _enabled = true;
    _noticeVersion = kConsentNoticeVersion;
    _grantedAtMs = _nowMs();
    _withdrawnAtMs = 0;
    await _persist();
  }

  /// One-tap withdrawal (DPDP s.6(4)–(6)): disable, stamp the withdrawal time,
  /// persist, then erase on-device aggregate state (s.8(7)/s.12) via [onWithdraw].
  /// Consent is disabled even if erasure fails — cease processing immediately.
  Future<void> withdraw() async {
    _enabled = false;
    _withdrawnAtMs = _nowMs();
    await _persist();
    try {
      await onWithdraw?.call();
    } catch (e) {
      dev.log('onWithdraw erasure hook failed (consent already off): $e',
          name: 'MobilityConsentService');
    }
  }

  /// Exportable proof of the specific consent (DPDP Rule-3 evidence).
  String consentReceiptJson() => jsonEncode({
        'app': 'GeoWake',
        'purpose':
            'anonymous aggregated station-to-station travel-flow statistics',
        'enabled': _enabled,
        'noticeVersion': _noticeVersion,
        'grantedAtMs': _grantedAtMs,
        'withdrawnAtMs': _withdrawnAtMs,
        'kAnonymityThreshold': kOdKAnonymityThreshold,
        'epsilonPerCell': kEpsilonPerCell,
      });
}
