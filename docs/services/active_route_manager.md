# ActiveRouteManager (lib/services/active_route_manager.dart)

Purpose: Maintains the active route and manages candidate switching with sustain and blackout to prevent flapping.

Key constructs:
- Inputs: `RouteRegistry registry`, `sustainDuration`, `switchMarginMeters`, `postSwitchBlackout`.
- Streams:
  - `stateStream`: emits `ActiveRouteState { activeKey, snapped, offsetMeters, progressMeters, remainingMeters, pendingSwitchToKey, pendingSwitchInSeconds }` each ingest.
  - `switchStream`: emits `RouteSwitchEvent { fromKey, toKey, at }` when a switch is committed.

Flow (per `ingestPosition`):
- Snap to active route: `SnapToRouteEngine.snap(entry.points)`; update `lastSnapIndex` and `lastProgressMeters` in `RouteRegistry`.
- Gather nearby candidates: `registry.candidatesNear(raw, radius≈1200m, max=3)`.
- Pick best by lateral offset with margin: require `candidateOffset + switchMargin < activeOffset` and a minimal heading/progress agreement (`_headingAgreement` > 0.3).
- Sustain/blackout:
  - If bestKey != activeKey and not in blackout: start/continue `_candidateTimer`. When `elapsed >= sustainDuration`, commit switch and start `_blackoutTimer`.
  - If in blackout or bestKey == activeKey: clear candidate.
- Pending switch countdown in state: when candidate active and not in blackout, report `pendingSwitchInSeconds = (sustain - elapsed)`; otherwise null.
- Remaining distance: computed from active entry length minus current progress.

Why this design:
- Offset-based heuristic is robust and cheap; sustain prevents flicker; blackout avoids immediate back-and-forth after a switch.
- Progress agreement ensures we’re not switching to a route going the wrong way when GPS jitters.

Interactions:
- TrackingService subscribes to `stateStream` to forward user progress and ETA metrics and to feed DeviationMonitor offset checks consistently (using active-route snap for offset).
- Route switches are surfaced to UI via `routeSwitchStream` for user awareness.