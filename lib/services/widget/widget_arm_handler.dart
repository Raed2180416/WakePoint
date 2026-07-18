// lib/services/widget/widget_arm_handler.dart
//
// GeoWake home-screen widget — launch-intent / interactivity handler
// (FEATURES_SPEC §3.6-A).
//
// The widget's primary button emits a deep-link URI. This file:
//   1. Parses that URI into a typed [WidgetArmRequest] (scheme-agnostic).
//   2. Decides — via the PURE [WidgetArmDecision.evaluate] truth table — whether
//      a tap could be a provably-safe one-tap arm or must instead open the app.
//   3. Executes safely: it NEVER arms directly from the background isolate and
//      NEVER double-arms a live journey. The actual arm always runs through the
//      app's own proven arm flow in the foreground (the never-late spine is
//      untouched); the handler only hands it a pending route id.
//
// WHY NOT ARM HEADLESS: Android 12+ forbids starting a location foreground
// service from the background without a visible activity, so a truly headless
// arm from the widget isolate would be blocked by the OS — exactly the "silently
// arm a dead alarm" failure the spec forbids. So the safe design is: bring the
// app to the foreground and let the normal arm pipeline (permissions, reliability
// preflight, startTracking) run. [WidgetArmDecision] still classifies the tap so
// the truth-table contract + tests hold, and a future in-foreground fast-path can
// consume [WidgetArmMode.headless] without changing this contract.
//
// HARD CONSTRAINTS honoured: additive, fail-safe (every entry point is wrapped),
// shares the active-session guard (TrackingStateStore.isActive) so the widget can
// never double-arm, and reads entitlement null-safely (null ⇒ not Pro ⇒ paywall).
// Every user-facing string says "GeoWake".

import 'dart:async';
import 'dart:developer' as dev;

import 'package:shared_preferences/shared_preferences.dart';

import 'package:geowake2/services/monetization/monetization_service.dart';
import 'package:geowake2/services/navigation_service.dart';
import 'package:geowake2/services/tracking_state_store.dart';
import 'package:geowake2/widgets/monetization/pro_gate.dart';

/// The deep-link scheme GeoWake's widget uses. Kept lowercase; the parser is
/// scheme-agnostic and also accepts the package's `homeWidget://` scheme.
const String kWidgetScheme = 'geowake';

/// Actions the widget can request.
enum WidgetAction { arm, stop, open, unknown }

/// How a tap should be serviced.
enum WidgetArmMode {
  /// Provably safe to arm without further user interaction (perms + a cached
  /// route for the current origin + a clean reliability preflight). Reserved for
  /// a future in-foreground fast-path; today it still routes through the normal
  /// foreground arm flow (never a background-isolate arm).
  headless,

  /// Must open the app and let the user complete arming in the normal flow
  /// (missing perms, no cached route, or a blocking reliability issue).
  launchApp,
}

/// Coarse reliability-preflight verdict, mirrored as a plain enum so the pure
/// decision function needs no dependency on the reliability layer.
enum WidgetPreflightState { ok, warn, block, unknown }

/// A parsed widget deep link.
class WidgetArmRequest {
  const WidgetArmRequest({required this.action, this.routeId, this.paywall = false});

  final WidgetAction action;
  final String? routeId;

  /// True when an `open` request specifically wants the paywall (locked card).
  final bool paywall;

  /// Parse a URI into a request. Scheme-agnostic and null-safe: an unparseable
  /// or absent URI yields [WidgetAction.unknown] rather than throwing.
  ///
  /// Recognised forms (host OR first path segment carries the verb):
  ///   `geowake://arm?routeId=<id>`
  ///   `geowake://widget/arm?routeId=<id>`
  ///   `geowake://stop`
  ///   `geowake://open` (optional `?paywall=1`)
  ///   `homeWidget://arm?routeId=<id>` (package default scheme)
  factory WidgetArmRequest.parse(Uri? uri) {
    if (uri == null) return const WidgetArmRequest(action: WidgetAction.unknown);
    try {
      final verb = _extractVerb(uri);
      final routeId = uri.queryParameters['routeId'];
      switch (verb) {
        case 'arm':
          final id = (routeId != null && routeId.trim().isNotEmpty)
              ? routeId.trim()
              : null;
          return WidgetArmRequest(action: WidgetAction.arm, routeId: id);
        case 'stop':
          return const WidgetArmRequest(action: WidgetAction.stop);
        case 'open':
          final paywall = uri.queryParameters['paywall'] == '1' ||
              uri.queryParameters['paywall'] == 'true';
          return WidgetArmRequest(action: WidgetAction.open, paywall: paywall);
        default:
          return const WidgetArmRequest(action: WidgetAction.unknown);
      }
    } catch (e) {
      dev.log('widget URI parse failed: $e', name: 'WidgetArmHandler');
      return const WidgetArmRequest(action: WidgetAction.unknown);
    }
  }

  static String _extractVerb(Uri uri) {
    final host = uri.host.toLowerCase();
    if (host == 'arm' || host == 'stop' || host == 'open') return host;
    // Fall back to the first non-empty path segment (e.g. geowake://widget/arm).
    for (final seg in uri.pathSegments) {
      final s = seg.toLowerCase();
      if (s == 'arm' || s == 'stop' || s == 'open') return s;
    }
    return '';
  }
}

/// PURE decision core — the §3.6 "one-tap = headless fast-path ONLY when provably
/// safe" truth table. No I/O, fully unit-testable.
class WidgetArmDecision {
  const WidgetArmDecision._();

  /// Decide how an arm tap should be serviced.
  ///
  /// Headless (fast-path) is permitted ONLY when ALL of:
  ///   • location/notification permissions are granted,
  ///   • a route is cached for the current origin (no Directions call needed),
  ///   • the reliability preflight is clean ([WidgetPreflightState.ok]).
  /// Anything else — missing perms, no cached route, a warn/block/unknown
  /// preflight — falls back to opening the app so the user resolves it in the
  /// normal flow. We never silently arm past a blocking or unknown state.
  static WidgetArmMode evaluate({
    required bool permsGranted,
    required bool hasCachedRouteForOrigin,
    required WidgetPreflightState preflight,
  }) {
    if (!permsGranted) return WidgetArmMode.launchApp;
    if (!hasCachedRouteForOrigin) return WidgetArmMode.launchApp;
    if (preflight != WidgetPreflightState.ok) return WidgetArmMode.launchApp;
    return WidgetArmMode.headless;
  }
}

/// Handles widget taps in the foreground app and (for background-safe actions)
/// from the interactivity isolate. Singleton.
class WidgetArmHandler {
  WidgetArmHandler._();
  static final WidgetArmHandler instance = WidgetArmHandler._();

  /// SharedPreferences key holding a route id the widget asked to arm, waiting
  /// for the app to reach a foreground state where the normal arm flow can run.
  static const String pendingArmKey = 'gw_widget_pending_arm_v1';

  // --- URI builders (used by the bridge to populate button deep links) -------

  static Uri buildArmUri(String routeId) =>
      Uri(scheme: kWidgetScheme, host: 'arm', queryParameters: {'routeId': routeId});

  static Uri buildOpenUri({bool paywall = false}) => Uri(
        scheme: kWidgetScheme,
        host: 'open',
        queryParameters: paywall ? const {'paywall': '1'} : null,
      );

  static Uri buildStopUri() => Uri(scheme: kWidgetScheme, host: 'stop');

  // --- foreground entry point (widgetClicked stream / cold launch) -----------

  /// Handle a LAUNCH-intent URI delivered while (or as) the app comes to the
  /// foreground. Never throws. Applies the shared active-session guard so a tap
  /// can never double-arm an in-flight journey.
  Future<void> handleLaunchUri(Uri? uri) async {
    try {
      final req = WidgetArmRequest.parse(uri);
      switch (req.action) {
        case WidgetAction.arm:
          await _handleArm(req.routeId);
          break;
        case WidgetAction.open:
          if (req.paywall) {
            _navigate(ProGate.paywallRoute, arg: PaywallSource.widget);
          } else {
            _navigate('/');
          }
          break;
        case WidgetAction.stop:
          // A stop request just opens the live journey so the user can end it
          // deliberately — the widget never silently tears down tracking.
          _navigate('/mapTracking');
          break;
        case WidgetAction.unknown:
          _navigate('/');
          break;
      }
    } catch (e) {
      dev.log('handleLaunchUri failed: $e', name: 'WidgetArmHandler');
    }
  }

  Future<void> _handleArm(String? routeId) async {
    // Entitlement gate (null-safe): a non-Pro / not-yet-loaded user is sent to
    // the paywall, never to a working arm.
    final canUse =
        MonetizationService.instance.premiumOrNull?.canUseWidget ?? false;
    if (!canUse) {
      _navigate(ProGate.paywallRoute, arg: PaywallSource.widget);
      return;
    }

    // Shared active-session guard: if a journey is already live, DO NOT arm —
    // just surface the active trip. This is the §3.1/§3.6 double-arm protection.
    bool active = false;
    try {
      active = await TrackingStateStore.isActive();
    } catch (_) {/* treat as inactive; the arm flow re-checks anyway */}
    if (active) {
      _navigate('/mapTracking');
      return;
    }

    if (routeId == null || routeId.isEmpty) {
      // No specific route — just open home so the user picks one.
      _navigate('/');
      return;
    }

    // Stash the request and bring home to the foreground; HomeScreen drains it
    // and runs its normal one-tap arm (permissions + reliability preflight +
    // startTracking). The never-late spine runs unchanged.
    await _setPendingArm(routeId);
    _navigate('/');
  }

  // --- pending-arm handoff (consumed by HomeScreen) --------------------------

  Future<void> _setPendingArm(String routeId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(pendingArmKey, routeId);
    } catch (e) {
      dev.log('failed to persist pending arm: $e', name: 'WidgetArmHandler');
    }
  }

  /// Read and clear a pending widget-arm route id, if any. HomeScreen calls this
  /// on init/resume and, when non-null, arms the matching remembered route
  /// through its existing one-tap flow. Returns null when nothing is pending.
  Future<String?> consumePendingArm() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final id = prefs.getString(pendingArmKey);
      if (id != null) await prefs.remove(pendingArmKey);
      return (id != null && id.isNotEmpty) ? id : null;
    } catch (e) {
      dev.log('failed to read pending arm: $e', name: 'WidgetArmHandler');
      return null;
    }
  }

  void _navigate(String route, {Object? arg}) {
    try {
      final nav = NavigationService.navigatorKey.currentState;
      if (nav == null) return; // no UI yet; pending-arm handoff covers cold start
      if (route == '/') {
        nav.popUntil((r) => r.isFirst);
      } else {
        nav.pushNamed(route, arguments: arg);
      }
    } catch (e) {
      dev.log('widget navigate failed: $e', name: 'WidgetArmHandler');
    }
  }

  /// Test seam.
  Future<void> clearPendingForTests() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(pendingArmKey);
    } catch (_) {}
  }
}

/// Background interactivity callback (interactive-widget button taps that arrive
/// in a headless isolate). Must be a top-level, `vm:entry-point`-annotated
/// function so it survives release tree-shaking.
///
/// SAFETY: this may run process-dead, where we can neither arm (OS foreground
/// restrictions) nor navigate. So for an `arm` tap it only records the pending
/// route id under the shared active-session guard — the widget's LAUNCH intent
/// brings the app foreground where [WidgetArmHandler.handleLaunchUri] /
/// HomeScreen finish the job. It NEVER starts tracking here, so the never-late
/// spine can never be touched from the background isolate.
@pragma('vm:entry-point')
FutureOr<void> widgetInteractivityCallback(Uri? uri) async {
  try {
    final req = WidgetArmRequest.parse(uri);
    if (req.action != WidgetAction.arm) return;

    // Shared active-session guard — never queue an arm over a live journey.
    bool active = false;
    try {
      active = await TrackingStateStore.isActive();
    } catch (_) {}
    if (active) return;

    final id = req.routeId;
    if (id == null || id.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(WidgetArmHandler.pendingArmKey, id);
  } catch (e) {
    dev.log('widgetInteractivityCallback failed: $e', name: 'WidgetArmHandler');
  }
}
