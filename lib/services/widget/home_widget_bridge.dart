// lib/services/widget/home_widget_bridge.dart
//
// GeoWake home-screen widget — Dart → native state bridge (FEATURES_SPEC §3.6-A).
//
// Responsibility: mirror the app's next-commute / active-trip state into the
// Android App Widget by writing a small set of key/value fields the native
// layout reads, then asking the platform to redraw. The widget is a Pro
// surface (PremiumService.canUseWidget) — when the user isn't Pro (or the
// entitlement layer hasn't loaded yet) the widget renders a locked "upsell"
// state that deep-links to the paywall; it NEVER exposes a working one-tap arm
// to a free user.
//
// HARD CONSTRAINTS honoured here:
//   • Additive + fail-safe. Every native call is wrapped so a missing/broken
//     home_widget plugin can NEVER throw into a caller on the arm/track/alarm
//     spine. A widget write failing is a no-op, not an app failure.
//   • The core never-late alarm is never gated, slowed, or touched. This file
//     only READS already-computed tracking state (the progress payload and the
//     active flag) and route memory; it computes nothing the alarm depends on.
//   • Entitlement is read null-safely via MonetizationService.premiumOrNull —
//     null (before init) resolves to "not Pro" ⇒ locked state, never a broken
//     unlocked tap.
//   • Every user-facing string says "GeoWake".
//
// The state-selection LOGIC is factored into the pure [resolveRenderState] so it
// is unit-testable with no plugin and no device.

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;

import 'package:home_widget/home_widget.dart';

import 'package:geowake2/services/monetization/monetization_service.dart';
import 'package:geowake2/services/saved_route.dart';
import 'package:geowake2/services/saved_routes_service.dart';
import 'package:geowake2/services/tracking_state_store.dart';
import 'package:geowake2/services/widget/widget_arm_handler.dart';
import 'package:geowake2/services/widget/widget_render_state.dart';

export 'package:geowake2/services/widget/widget_render_state.dart'
    show WidgetRenderState, resolveRenderState;

/// Immutable snapshot of everything the native layout needs. Serialised to the
/// discrete widget-data keys the Kotlin provider reads, plus a single JSON blob
/// under [HomeWidgetBridge.stateBlobKey] for debugging / the in-app preview.
class WidgetStateData {
  const WidgetStateData({
    required this.state,
    required this.title,
    required this.subtitle,
    required this.progressPercent,
    required this.ctaLabel,
    required this.deepLink,
    this.routeId,
  });

  final WidgetRenderState state;
  final String title;
  final String subtitle;

  /// 0..100 (int) so the native RemoteViews ProgressBar can consume it directly.
  final int progressPercent;

  /// Label for the widget's primary button.
  final String ctaLabel;

  /// URI the primary button fires (a [WidgetArmHandler] deep link).
  final String deepLink;

  /// Route-memory id backing an idle arm candidate (null otherwise).
  final String? routeId;

  Map<String, String> toWidgetFields() => <String, String>{
        HomeWidgetBridge.fState: state.name,
        HomeWidgetBridge.fTitle: title,
        HomeWidgetBridge.fSubtitle: subtitle,
        HomeWidgetBridge.fProgress: progressPercent.toString(),
        HomeWidgetBridge.fCta: ctaLabel,
        HomeWidgetBridge.fDeepLink: deepLink,
        HomeWidgetBridge.fRouteId: routeId ?? '',
      };

  Map<String, dynamic> toJson() => <String, dynamic>{
        'state': state.name,
        'title': title,
        'subtitle': subtitle,
        'progress': progressPercent,
        'cta': ctaLabel,
        'deepLink': deepLink,
        'routeId': routeId,
      };
}

/// Singleton that owns the one-way push of app state → home widget.
class HomeWidgetBridge {
  HomeWidgetBridge._();
  static final HomeWidgetBridge instance = HomeWidgetBridge._();

  /// Android provider class (native `AppWidgetProvider` subclass). Must match
  /// the `<receiver android:name>` in the merged manifest (see WIRING).
  static const String androidProviderName = 'GeoWakeWidgetProvider';
  static const String androidQualifiedName =
      'com.example.geowake2.GeoWakeWidgetProvider';

  /// Discrete widget-data keys the native layout binds to.
  static const String fState = 'gw_widget_state';
  static const String fTitle = 'gw_widget_title';
  static const String fSubtitle = 'gw_widget_subtitle';
  static const String fProgress = 'gw_widget_progress';
  static const String fCta = 'gw_widget_cta';
  static const String fDeepLink = 'gw_widget_deeplink';
  static const String fRouteId = 'gw_widget_route_id';

  /// Single JSON blob (debug / in-app preview). Native side ignores it.
  static const String stateBlobKey = 'gw_widget_state_v1';

  /// Coalesce bursty refreshes (progress ticks arrive ~1/sec). We push at most
  /// once per this interval; the latest state always wins.
  static const Duration _minPushInterval = Duration(seconds: 8);

  bool _initialised = false;
  bool _pluginUsable = true;
  DateTime _lastPush = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _pending;
  StreamSubscription<dynamic>? _clickSub;

  /// Wire up widget interactivity once, at app start. Fail-open: any failure
  /// (plugin absent on this build, platform channel missing) disables the
  /// bridge for the session rather than surfacing an error. Safe to call more
  /// than once.
  Future<void> initialize() async {
    if (_initialised) return;
    _initialised = true;
    try {
      // Route background button taps (interactive widget) through our handler.
      await HomeWidget.registerInteractivityCallback(
        widgetInteractivityCallback,
      );
    } catch (e) {
      _pluginUsable = false;
      dev.log('home_widget interactivity unavailable: $e',
          name: 'HomeWidgetBridge');
    }
    try {
      // App already running: a widget LAUNCH tap arrives here.
      _clickSub = HomeWidget.widgetClicked.listen(
        (uri) => WidgetArmHandler.instance.handleLaunchUri(uri),
        onError: (_) {},
      );
    } catch (e) {
      dev.log('home_widget click stream unavailable: $e',
          name: 'HomeWidgetBridge');
    }
    try {
      // Cold start FROM a widget tap: replay the launch URI once.
      final launch = await HomeWidget.initiallyLaunchedFromHomeWidget();
      if (launch != null) {
        await WidgetArmHandler.instance.handleLaunchUri(launch);
      }
    } catch (_) {/* best effort */}
    // Paint an initial state so the widget isn't blank on first add.
    unawaited(refresh());
  }

  /// Recompute the widget's state from live app state and push it. Debounced.
  /// Never throws. Call from tracking start/stop, progress ticks (throttled by
  /// the caller AND here), route-memory changes, and entitlement changes.
  Future<void> refresh({bool immediate = false}) async {
    if (!_pluginUsable) return;
    if (!immediate) {
      final since = DateTime.now().difference(_lastPush);
      if (since < _minPushInterval) {
        // Collapse into a single trailing push.
        _pending?.cancel();
        _pending = Timer(_minPushInterval - since, () {
          unawaited(_computeAndPush());
        });
        return;
      }
    }
    _pending?.cancel();
    await _computeAndPush();
  }

  Future<void> _computeAndPush() async {
    _lastPush = DateTime.now();
    WidgetStateData data;
    try {
      data = await _computeState();
    } catch (e) {
      dev.log('widget state compute failed: $e', name: 'HomeWidgetBridge');
      // Fail-safe: a neutral, always-valid card.
      data = _emptyCard();
    }
    await _push(data);
  }

  /// Explicitly clear the widget to its neutral prompt (e.g. user disabled the
  /// widget in Settings, or Pro lapsed).
  Future<void> clear() => _push(_emptyCard());

  // --- state computation ----------------------------------------------------

  Future<WidgetStateData> _computeState() async {
    final canUse =
        MonetizationService.instance.premiumOrNull?.canUseWidget ?? false;

    bool active = false;
    try {
      active = await TrackingStateStore.isActive();
    } catch (_) {/* treat as inactive */}

    RouteMemory? candidate;
    if (canUse && !active) {
      candidate = await _topCandidate();
    }

    final state = resolveRenderState(
      canUseWidget: canUse,
      isActive: active,
      hasCandidate: candidate != null,
    );

    switch (state) {
      case WidgetRenderState.locked:
        return _lockedCard();
      case WidgetRenderState.active:
        return await _activeCard();
      case WidgetRenderState.idle:
        return _idleCard(candidate!);
      case WidgetRenderState.empty:
        return _emptyCard();
    }
  }

  Future<RouteMemory?> _topCandidate() async {
    try {
      final routes = await RouteMemoryService.list();
      return routes.isEmpty ? null : routes.first;
    } catch (_) {
      return null;
    }
  }

  WidgetStateData _lockedCard() => WidgetStateData(
        state: WidgetRenderState.locked,
        title: 'GeoWake Pro',
        subtitle: 'Add your commute to the home screen and arm in one tap.',
        progressPercent: 0,
        ctaLabel: 'Unlock',
        deepLink: WidgetArmHandler.buildOpenUri(paywall: true).toString(),
      );

  Future<WidgetStateData> _activeCard() async {
    String title = 'GeoWake';
    String subtitle = 'Tracking your journey';
    int pct = 0;
    try {
      final payload = await TrackingStateStore.loadProgressPayload();
      if (payload != null) {
        title = payload.title.isEmpty ? 'GeoWake' : payload.title;
        subtitle = payload.subtitle.isEmpty
            ? 'Tracking your journey'
            : payload.subtitle;
        pct = (payload.progress.clamp(0.0, 1.0) * 100).round();
      }
    } catch (_) {/* neutral active card */}
    return WidgetStateData(
      state: WidgetRenderState.active,
      title: title,
      subtitle: subtitle,
      progressPercent: pct,
      ctaLabel: 'Open',
      deepLink: WidgetArmHandler.buildOpenUri().toString(),
    );
  }

  WidgetStateData _idleCard(RouteMemory r) {
    final name = r.destinationName.trim().isEmpty
        ? 'your recent trip'
        : r.destinationName.trim();
    return WidgetStateData(
      state: WidgetRenderState.idle,
      title: name,
      subtitle: r.isFrequent
          ? 'Frequent trip · tap to arm'
          : 'Recent trip · tap to arm',
      progressPercent: 0,
      ctaLabel: 'Arm',
      deepLink: WidgetArmHandler.buildArmUri(r.id).toString(),
      routeId: r.id,
    );
  }

  WidgetStateData _emptyCard() => WidgetStateData(
        state: WidgetRenderState.empty,
        title: 'GeoWake',
        subtitle: 'Open GeoWake to set up your next commute.',
        progressPercent: 0,
        ctaLabel: 'Open',
        deepLink: WidgetArmHandler.buildOpenUri().toString(),
      );

  // --- native push ----------------------------------------------------------

  Future<void> _push(WidgetStateData data) async {
    if (!_pluginUsable) return;
    try {
      final fields = data.toWidgetFields();
      for (final entry in fields.entries) {
        await HomeWidget.saveWidgetData<String>(entry.key, entry.value);
      }
      // Debug/preview blob — native side ignores it.
      await HomeWidget.saveWidgetData<String>(
        stateBlobKey,
        jsonEncode(data.toJson()),
      );
      await HomeWidget.updateWidget(
        name: androidProviderName,
        androidName: androidProviderName,
        qualifiedAndroidName: androidQualifiedName,
      );
    } catch (e) {
      // A failed write must never propagate — mark unusable so we stop trying
      // this session and silently no-op.
      _pluginUsable = false;
      dev.log('home_widget push failed (disabling for session): $e',
          name: 'HomeWidgetBridge');
    }
  }

  /// Test seam: reset internal state between tests.
  void resetForTests() {
    _initialised = false;
    _pluginUsable = true;
    _lastPush = DateTime.fromMillisecondsSinceEpoch(0);
    _pending?.cancel();
    _pending = null;
    _clickSub?.cancel();
    _clickSub = null;
  }
}
