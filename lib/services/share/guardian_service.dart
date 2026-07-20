// lib/services/share/guardian_service.dart
//
// GUARDIAN MODE (Pro) — auto-share every commute with a saved contact and send
// an "arrived safely" signal when the wake alarm fires.
//
// GATING: every MUTATING call first checks canUseGuardianMode; a non-Pro caller
// gets a GuardianDenied (setup UI shows the paywall instead). Reads are always
// safe. Default state is OPT-OUT (enabled == false) — a fresh Pro user shares
// nothing until they turn Guardian on and pick a contact.
//
// CORE-SAFETY: the "arrived" trigger hangs off PostAlarmMulticast — a
// fire-and-forget observer invoked AFTER the wake is already raised, each
// listener isolated. Guardian NEVER hooks the synchronous pre-alarm
// onDestinationAlarmFired path, so a Guardian failure (un-opened box, null
// contact, network hang) can never delay or abort the ring. Everything here is
// wrapped and swallowed.

import 'dart:async';
import 'dart:developer' as dev;

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../monetization/monetization_service.dart';
import '../tracking/post_alarm_multicast.dart';
import 'journey_share_models.dart';
import 'journey_share_service.dart';
import 'share_link_builder.dart';

/// Thrown when a mutating Guardian call is attempted without the Pro
/// entitlement. UI catches this and routes to the paywall.
class GuardianDenied implements Exception {
  final String message;
  const GuardianDenied([this.message = 'Guardian mode requires GeoWake Pro']);
  @override
  String toString() => 'GuardianDenied: $message';
}

/// Opens a composer/deep-link URI (an `sms:` or `https://wa.me/…` link). Returns
/// whether the OS accepted it. Injectable so delivery is unit-testable.
typedef GuardianUriLauncher = Future<bool> Function(Uri uri);

/// CONFIG PLACEHOLDER — automatic, no-user-tap delivery (Twilio SMS / WhatsApp
/// Business API / FCM push). Business-gated: defaults to null so GeoWake ships
/// NO SMS gateway. When a founder wires a sender here, Guardian delivers without
/// user mediation; until then every message is composed into the user's OWN
/// SMS/WhatsApp composer for the user to send.
typedef GuardianAutoSender = Future<void> Function(
    GuardianContact contact, String message);

class GuardianService {
  GuardianService._({
    bool Function()? entitlement,
    JourneyShareService? share,
    GuardianUriLauncher? launcher,
    GuardianAutoSender? autoSender,
  })  : _entitlement = entitlement ??
            (() =>
                MonetizationService.instance.premiumOrNull?.canUseGuardianMode ??
                false),
        _share = share ?? JourneyShareService.instance,
        _launcher = launcher ?? _defaultLaunch {
    autoDeliverySender = autoSender;
  }

  static final GuardianService instance = GuardianService._();

  /// Test factory — inject the entitlement read, share service, and launcher.
  /// The launcher defaults to a silent no-op so tests never touch the platform
  /// url_launcher channel.
  factory GuardianService.forTest({
    required bool Function() entitlement,
    JourneyShareService? share,
    GuardianUriLauncher? launcher,
    GuardianAutoSender? autoSender,
  }) =>
      GuardianService._(
        entitlement: entitlement,
        share: share,
        launcher: launcher ?? ((Uri _) async => true),
        autoSender: autoSender,
      );

  /// Real out-of-app launch: hands the composer URI to the OS (SMS / WhatsApp).
  static Future<bool> _defaultLaunch(Uri uri) =>
      launchUrl(uri, mode: LaunchMode.externalApplication);

  static const String contactsBox = 'gw_guardian_contacts';
  static const String enabledBox = 'gw_guardian_enabled';
  static const String _contactKey = 'contact';
  static const String _enabledKey = 'enabled';

  final bool Function() _entitlement;
  final JourneyShareService _share;
  final GuardianUriLauncher _launcher;
  final Uuid _uuid = const Uuid();

  /// Business-gated automatic sender (see [GuardianAutoSender]). Null by default
  /// (no SMS gateway shipped) → delivery falls back to the user-mediated
  /// composer deep link. A founder may set this once a paid backend is wired.
  GuardianAutoSender? autoDeliverySender;

  /// Reactive: the Guardian on/off state for UI toggles.
  final ValueNotifier<bool> enabledListenable = ValueNotifier<bool>(false);

  bool _registered = false;
  bool _loaded = false;
  bool _enabled = false;
  GuardianContact? _contact;

  /// The destination label for the CURRENT guardian journey (for the "arrived
  /// safely" message). Null between journeys.
  String? _activeDestLabel;

  /// Entitlement read (safe to call anywhere).
  bool get isAllowed => _entitlement();

  // ---------------------------------------------------------------------------
  // lifecycle
  // ---------------------------------------------------------------------------

  /// Load persisted state and register the post-alarm observer. Fail-open —
  /// any failure leaves Guardian disabled but never blocks startup.
  Future<void> init() async {
    try {
      await _load();
      registerPostAlarm();
    } catch (e) {
      dev.log('Guardian init ignored: $e', name: 'GuardianService');
    }
  }

  /// Register the fire-and-forget arrived observer exactly once.
  void registerPostAlarm() {
    if (_registered) return;
    _registered = true;
    PostAlarmMulticast.instance.addListener(_onAlarmFired);
  }

  Future<void> _load() async {
    if (_loaded) return;
    try {
      final eBox = await _openBox(enabledBox);
      _enabled = (eBox?.get(_enabledKey)) == 'true';
      final cBox = await _openBox(contactsBox);
      final raw = cBox?.get(_contactKey);
      _contact = raw != null ? GuardianContact.decode(raw) : null;
    } catch (_) {
      _enabled = false;
      _contact = null;
    }
    _loaded = true;
    enabledListenable.value = _enabled && _contact != null;
  }

  // ---------------------------------------------------------------------------
  // reads
  // ---------------------------------------------------------------------------

  Future<bool> isEnabled() async {
    await _load();
    return _enabled;
  }

  Future<GuardianContact?> getContact() async {
    await _load();
    return _contact;
  }

  /// True only when Pro AND enabled AND a contact is set.
  Future<bool> isActiveGuard() async {
    await _load();
    return isAllowed && _enabled && _contact != null;
  }

  // ---------------------------------------------------------------------------
  // mutations (all Pro-gated)
  // ---------------------------------------------------------------------------

  /// Save (or replace) the guardian contact. [id] is minted if absent.
  Future<GuardianContact> setContact({
    required String displayName,
    required GuardianChannel channel,
    required String address,
  }) async {
    _requirePro();
    await _load();
    final contact = GuardianContact(
      id: _contact?.id ?? _uuid.v4(),
      displayName: displayName.trim(),
      channel: channel,
      address: address.trim(),
    );
    final box = await _openBox(contactsBox);
    await box?.put(_contactKey, contact.encode());
    _contact = contact;
    enabledListenable.value = _enabled && _contact != null;
    return contact;
  }

  /// Remove the saved contact (also disables Guardian).
  Future<void> clearContact() async {
    _requirePro();
    await _load();
    final box = await _openBox(contactsBox);
    await box?.delete(_contactKey);
    _contact = null;
    await _setEnabledInternal(false);
  }

  /// Enable / disable Guardian mode.
  Future<void> setEnabled(bool value) async {
    _requirePro();
    await _load();
    if (value && _contact == null) {
      throw const GuardianDenied('Pick a Guardian contact first');
    }
    await _setEnabledInternal(value);
  }

  Future<void> _setEnabledInternal(bool value) async {
    final box = await _openBox(enabledBox);
    await box?.put(_enabledKey, value ? 'true' : 'false');
    _enabled = value;
    enabledListenable.value = _enabled && _contact != null;
  }

  // ---------------------------------------------------------------------------
  // journey hooks (called from the arm flow + post-alarm path)
  // ---------------------------------------------------------------------------

  /// Auto-share when a journey is armed. Fire-and-forget; safe to call for every
  /// arm — it no-ops unless Pro + enabled + contact set. Never throws.
  Future<void> onJourneyArmed({String? destLabel, DateTime? eta}) async {
    try {
      if (!await isActiveGuard()) return;
      final started = await _share.startBasicShare(
        destLabel: destLabel,
        eta: eta,
        mode: ShareMode.guardian,
      );
      _activeDestLabel = destLabel;
      // Deliver the tracking link to the saved contact. Fire-and-forget: opens
      // the user's SMS/WhatsApp composer pre-filled (user taps send), or an
      // automatic sender if a founder has wired one.
      unawaited(_notifyContact(started.message));
    } catch (e) {
      dev.log('onJourneyArmed ignored: $e', name: 'GuardianService');
    }
  }

  /// The post-alarm observer. Runs on its own microtask (see PostAlarmMulticast)
  /// AFTER the wake is raised. Fires the "arrived safely" signal and clears the
  /// active journey. Everything is fire-and-forget; a failure is swallowed.
  void _onAlarmFired() {
    // Do NOT await here — the multicast contract is non-blocking. Kick the
    // async work off and return immediately.
    unawaited(_deliverArrived());
  }

  Future<void> _deliverArrived() async {
    try {
      if (!await isActiveGuard()) return;
      // Mark the share arrived. JourneyShareService.markArrived already signals
      // the backend for each active session (the server-side "arrived safely"
      // push), so we do NOT call backend.markArrived again here.
      await _share.markArrived();
      // The follower already sees "arrived safely" via the backend (markArrived
      // above). Do NOT pop the user's SMS/WhatsApp composer here — that would
      // surface OVER the just-fired wake alarm / dismiss UI (and Android 12+
      // background-launch limits would likely block it anyway). Only the INERT,
      // founder-wired automatic sender may deliver at arrival; with none wired
      // (the default) the backend status is the arrival signal.
      final contact = _contact;
      final auto = autoDeliverySender;
      if (contact != null && auto != null) {
        final msg =
            ShareLinkBuilder.buildArrivedMessage(destLabel: _activeDestLabel);
        unawaited(auto(contact, msg));
      }
    } catch (e) {
      dev.log('arrived delivery ignored: $e', name: 'GuardianService');
    } finally {
      _activeDestLabel = null;
    }
  }

  /// Best-effort out-of-app delivery to the saved contact. Never throws.
  ///
  /// DELIVERY MODEL (free MVP, no SMS gateway): compose [message] into the
  /// user's OWN SMS or WhatsApp app, pre-addressed to the saved contact, so the
  /// USER taps send. GeoWake never sends a message itself. If a founder has
  /// wired [autoDeliverySender] (a paid Twilio/WhatsApp/FCM backend), that path
  /// takes over and delivers without user mediation.
  Future<void> _notifyContact(String message) async {
    try {
      final contact = _contact;
      if (contact == null) return;

      // Automatic server-side delivery is INERT unless a founder wired it.
      final auto = autoDeliverySender;
      if (auto != null) {
        unawaited(auto(contact, message));
        return;
      }

      final uri = composeDeepLink(contact, message);
      if (uri == null) return;
      // Opens the composer pre-filled; the user taps send. Best-effort.
      await _launcher(uri);
    } catch (e) {
      dev.log('notifyContact ignored: $e', name: 'GuardianService');
    }
  }

  /// Build the channel-specific composer URI for [contact] carrying [message].
  ///
  /// Pure and side-effect-free (unit-testable). Returns null when there is no
  /// usable address. WhatsApp → `https://wa.me/<digits>?text=…`; SMS (and the
  /// not-yet-implemented in-app channel) → `sms:<number>?body=…`.
  static Uri? composeDeepLink(GuardianContact contact, String message) {
    final addr = contact.address.trim();
    if (addr.isEmpty) return null;
    switch (contact.channel) {
      case GuardianChannel.whatsapp:
        final phone = addr.replaceAll(RegExp(r'[^0-9]'), '');
        if (phone.isEmpty) return null;
        return Uri.parse(
            'https://wa.me/$phone?text=${Uri.encodeComponent(message)}');
      case GuardianChannel.sms:
      case GuardianChannel.app: // no in-app transport yet → SMS composer
        final phone = addr.replaceAll(RegExp(r'[^0-9+]'), '');
        if (phone.isEmpty) return null;
        return Uri.parse('sms:$phone?body=${Uri.encodeComponent(message)}');
    }
  }

  // ---------------------------------------------------------------------------
  // helpers
  // ---------------------------------------------------------------------------

  void _requirePro() {
    if (!isAllowed) throw const GuardianDenied();
  }

  Future<Box<String>?> _openBox(String name) async {
    try {
      if (Hive.isBoxOpen(name)) return Hive.box<String>(name);
      return await Hive.openBox<String>(name);
    } catch (e) {
      dev.log('guardian box "$name" open failed: $e — recreating',
          name: 'GuardianService');
      try {
        await Hive.deleteBoxFromDisk(name);
        return await Hive.openBox<String>(name);
      } catch (e2) {
        dev.log('guardian box "$name" recreate failed: $e2',
            name: 'GuardianService');
        return null;
      }
    }
  }
}
