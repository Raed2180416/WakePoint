// lib/services/widget/widget_render_state.dart
//
// Pure state-selection policy for the GeoWake home-screen widget
// (FEATURES_SPEC §3.6-A). Deliberately dependency-free (no plugin, no I/O) so
// the precedence logic is trivially unit-testable on any host, mirroring the
// codebase convention of keeping decision logic pure and separately testable.

/// What the native widget should render right now.
enum WidgetRenderState {
  /// User is not Pro (or entitlement not yet loaded) — show an upsell card that
  /// deep-links to the paywall. No working arm control.
  locked,

  /// A journey is currently armed/tracking — show live progress + "Open".
  active,

  /// Idle but we have a remembered commute to offer as a one-tap arm candidate.
  idle,

  /// Idle with nothing to offer yet — show a neutral "open GeoWake" prompt.
  empty,
}

/// Pure state-selection policy.
///
/// Precedence: entitlement first (a non-Pro user never sees a working arm),
/// then an in-flight journey (the active session ALWAYS wins so the widget can
/// never present an "Arm" button that would double-arm — it shows "Open"
/// instead), then a remembered commute, else a neutral prompt.
WidgetRenderState resolveRenderState({
  required bool canUseWidget,
  required bool isActive,
  required bool hasCandidate,
}) {
  if (!canUseWidget) return WidgetRenderState.locked;
  if (isActive) return WidgetRenderState.active;
  if (hasCandidate) return WidgetRenderState.idle;
  return WidgetRenderState.empty;
}
