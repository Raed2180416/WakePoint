// lib/services/monetization/premium_service.dart
//
// Holds the user's entitlement (free vs Pro) and exposes the feature gates as
// pure getters. Two ways to become "Pro":
//   1. A permanent ONE-TIME "Pro" unlock (India prefers one-time over subs —
//      MONETIZATION §B, HANDOFF §5), purchased via the injected PurchaseBackend.
//   2. A temporary REWARDED "premium for a day" pass (opt-in rewarded video),
//      for price-sensitive users who trade attention not money.
//
// Design (mirrors telemetry_service.dart): the core is pure and dependency-
// injected — a PurchaseBackend for billing and a simple (key)->get /
// (key,value)->set persistence pair, both defaulting to in-memory — so the
// whole thing is deterministically unit-testable with no SDK and no device.
//
// THE INVARIANT THAT MATTERS: reliability/safety (the core alarm) is NEVER
// gated. The always-free getters below return true unconditionally, and
// [alwaysFreeCapabilities] documents the set. Gating the alarm would break the
// trust the whole product — and the future data business — rests on.

import 'dart:async';

import 'package:geowake2/services/monetization/purchase_backend.dart';

/// Store product ids. Kept here (not in the SDK layer) so tests and policy code
/// can reference them without importing `in_app_purchase`.
class PremiumProducts {
  /// The one-time, non-consumable Pro unlock. Lead SKU for India.
  static const String proOneTime = 'geowake_pro_onetime';
}

/// Coarse entitlement tier for UI / analytics.
enum EntitlementTier { free, pro }

/// Owns entitlement state and the feature gates derived from it.
class PremiumService {
  /// Persistence key holding the whole entitlement blob (one JSON value, like
  /// the app's other single-key stores).
  static const String persistKey = 'geowake_entitlement_v1';

  /// Product id whose ownership grants permanent Pro.
  static const String proProductId = PremiumProducts.proOneTime;

  /// Default duration of a rewarded "premium for a day" pass.
  static const Duration rewardedDayPassDuration = Duration(hours: 24);

  /// Reliability/safety capabilities that MUST work on the free tier. Gating
  /// any of these is a product-breaking bug (HANDOFF §5, MONETIZATION §B). The
  /// getters for these always return true regardless of entitlement.
  static const Set<String> alwaysFreeCapabilities = <String>{
    'coreAlarm',
    'basicReliability',
    'singleActiveRoute',
    'backstopAlarm',
  };

  final PurchaseBackend _backend;
  final int Function() _nowMs;

  // Injected persistence — default in-memory (per-instance map) if not given.
  late final Future<String?> Function(String key) _load;
  late final Future<void> Function(String key, String value) _save;

  // Entitlement state.
  bool _proOwned = false; // permanent one-time unlock
  int _dayPassExpiryMs = 0; // rewarded day-pass expiry (0 = none)

  PremiumService({
    required PurchaseBackend backend,
    Future<String?> Function(String key)? load,
    Future<void> Function(String key, String value)? save,
    int Function()? nowMs,
  })  : _backend = backend,
        _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch) {
    if (load != null && save != null) {
      _load = load;
      _save = save;
    } else {
      // Default: ephemeral in-memory store scoped to this instance.
      final mem = <String, String>{};
      _load = load ?? ((String k) async => mem[k]);
      _save = save ??
          ((String k, String v) async {
            mem[k] = v;
          });
    }
  }

  // ---------------------------------------------------------------------------
  // Entitlement lifecycle
  // ---------------------------------------------------------------------------

  /// Load persisted entitlement. Fail-safe: an unreadable/corrupt blob leaves
  /// the user on the free tier rather than throwing into app start-up.
  Future<void> load() async {
    try {
      final raw = await _load(persistKey);
      if (raw == null || raw.isEmpty) return;
      // Format: "<pro 0|1>;<dayPassExpiryMs>". A malformed blob leaves the user
      // on the free tier (fail-safe) rather than throwing into app start-up.
      // Encoded with dart:core only — no dart:convert dependency at module scope.
      final parts = raw.split(';');
      if (parts.length != 2) return;
      // STRICT, FAIL-CLOSED parse: never grant the paid unlock from ambiguous or
      // tampered persisted state. The flag must be exactly '0'/'1' and the expiry
      // exactly an integer with NO whitespace (int.tryParse(' 100') == 100 would
      // otherwise resurrect Pro from a malformed blob like "1; 100").
      final proStr = parts[0];
      final expStr = parts[1];
      if (proStr != '0' && proStr != '1') return;
      if (!RegExp(r'^-?\d+$').hasMatch(expStr)) return;
      final exp = int.tryParse(expStr);
      if (exp == null) return;
      _proOwned = proStr == '1';
      _dayPassExpiryMs = exp;
    } catch (_) {
      // Treat any failure as "free" — never block the app on entitlement I/O.
    }
  }

  Future<void> _persist() async {
    try {
      // Compact dart:core-only encoding (no dart:convert): the two scalar
      // fields joined by ';'. See [load] for the matching decoder.
      await _save(persistKey, '${_proOwned ? 1 : 0};$_dayPassExpiryMs');
    } catch (_) {
      // Persistence is best-effort; a lost write just re-prompts a restore.
    }
  }

  /// Buy the one-time Pro unlock. Returns true iff granted. Ownership is only
  /// recorded (and persisted) on a confirmed purchase — never on a decline.
  Future<bool> buyPro() async {
    final ok = await _backend.buyOneTime(proProductId);
    if (ok) {
      _proOwned = true;
      await _persist();
    }
    return ok;
  }

  /// Apply an ownership set delivered asynchronously by the store (e.g. a
  /// UPI/pending purchase that clears AFTER buyPro already returned, or a
  /// background restore). Idempotent: grants + persists Pro only when newly
  /// owned, so a late-arriving purchase never leaves a paying user on Free.
  Future<void> applyOwnedProducts(Set<String> owned) async {
    if (!_proOwned && owned.contains(proProductId)) {
      _proOwned = true;
      await _persist();
    }
  }

  /// Restore prior purchases (reinstall / new device). Re-grants permanent Pro
  /// if the store account owns [proProductId]. Returns the owned product ids.
  Future<Set<String>> restorePurchases() async {
    final owned = await _backend.restore();
    if (owned.contains(proProductId)) {
      _proOwned = true;
      await _persist();
    }
    return owned;
  }

  /// Grant a rewarded "premium for a day" pass (call after a rewarded video
  /// completes). Extends, never shortens, any existing pass.
  Future<void> grantRewardedDayPass({
    Duration duration = rewardedDayPassDuration,
  }) async {
    final expiry = _nowMs() + duration.inMilliseconds;
    if (expiry > _dayPassExpiryMs) _dayPassExpiryMs = expiry;
    await _persist();
  }

  // ---------------------------------------------------------------------------
  // Entitlement queries
  // ---------------------------------------------------------------------------

  /// Whether the permanent one-time Pro unlock is owned.
  bool get hasProOneTime => _proOwned;

  /// Whether a rewarded day-pass is currently active.
  bool get hasActiveDayPass => _nowMs() < _dayPassExpiryMs;

  /// Rewarded day-pass expiry (epoch ms; 0 if none). Exposed for UI countdowns.
  int get dayPassExpiryMs => _dayPassExpiryMs;

  /// The single source of truth for "is this user premium right now?" — true if
  /// the permanent unlock is owned OR a rewarded day-pass is active.
  bool get isPro => _proOwned || hasActiveDayPass;

  /// Coarse tier for UI / analytics.
  EntitlementTier get tier => isPro ? EntitlementTier.pro : EntitlementTier.free;

  // ---------------------------------------------------------------------------
  // ALWAYS-FREE gates — reliability & safety. NEVER return false.
  // ---------------------------------------------------------------------------

  /// The core wake alarm. Always free — this is the product and the trust base.
  bool get canUseCoreAlarm => true;

  /// Basic on-time reliability (FGS survival, exact-alarm backstop). Always free.
  bool get canUseBasicReliability => true;

  /// The redundant audible backstop channel. Always free — a safety net.
  bool get canUseBackstopAlarm => true;

  /// One active route/alarm at a time. Always free (multiple is the paid split).
  bool get canUseSingleActiveRoute => true;

  /// Defensive check: is [capability] one that must never be gated?
  static bool isAlwaysFree(String capability) =>
      alwaysFreeCapabilities.contains(capability);

  // ---------------------------------------------------------------------------
  // PREMIUM gates — convenience & polish. Gated behind [isPro].
  // ---------------------------------------------------------------------------

  /// Remove all ads. (AdPolicy already honours [isPro]; this mirrors it for UI.)
  bool get isAdFree => isPro;

  // NOTE: transfer/interchange alarms (wake at each transfer + destination on a
  // multi-leg journey) already ship and are FREE — there is no "multiple alarms"
  // Pro gate. Likewise there is no "saved routes", "recurring auto-arm", or
  // "offline / all-cities" gate: GeoWake is position-dependent (you must be
  // online and present to plan/start a route), so those don't fit the product.

  /// Custom alarm sounds, escalating vibration, gentle-wake.
  bool get canUseCustomAlarmSounds => isPro;

  /// Home-screen widget.
  bool get canUseWidget => isPro;

  /// Wear OS / watch alarm.
  bool get canUseWearOs => isPro;

  /// Family / shared alarms (wake a companion).
  bool get canUseFamilyAlarms => isPro;

  /// Guardian mode — auto-share every commute with a saved contact + an
  /// "arrived safely" push. (Basic one-off share is ALWAYS free; this is the
  /// automatic/continuous Pro variant.)
  bool get canUseGuardianMode => isPro;

  // NOTE: there is deliberately NO "snooze" gate. A wake-before-your-stop alarm
  // must never be delayable — snoozing would make the rider miss their stop.
  // The safety behaviour for that moment is escalating RE-ALERT-until-
  // acknowledged (see canUseCustomAlarmSounds / the alarm channel), not snooze.
}
