// lib/services/tracking/arrival_hooks.dart
//
// ARRIVAL HOOKS — the ONE fire-and-forget fan-out that lets the already-landed
// premium / growth features observe a COMPLETED GeoWake trip.
//
// It is invoked from a SINGLE call site: the destination-arrival ("You've
// reached …") END TRACKING handler in maptracking.dart, immediately AFTER
// `TrackingService.completeEndTracking()` has torn the session down. Bundling
// the four sinks here keeps the wiring at that call site to one additive line.
//
// ── CORE-SAFETY: why this can NEVER delay, reorder, or abort the never-late
//    wake (the product's whole promise) ─────────────────────────────────────
//   1. ORDERING. It runs only in the `_finalAlarmActive` branch, i.e. AFTER the
//      destination alarm has already fired, been acknowledged by the rider, and
//      `completeEndTracking()` has fully stopped the service / cleared state.
//      There is no reachability evaluation, no alarm dispatch, and no teardown
//      left to influence — the wake has already been delivered.
//   2. NON-BLOCKING. `fireArrived` is a synchronous `void`. Every sink call is
//      itself kicked off `unawaited(...)` inside its own try/catch, and the
//      whole body is wrapped in an outer try/catch, so no sink can throw, hang,
//      await, or otherwise block the caller. The call site does NOT await it and
//      it returns before any I/O runs.
//   3. NO CORE WORK. It performs zero alarm / reachability / tracking / teardown
//      work — only observation of an already-finished trip.
//
// The bundled sinks (each independently safe on its own):
//   1. DataAssetPipeline.onTripCompleted — opt-in aggregate surface. Self-gates
//                                           on consent (default OFF) as line one,
//                                           so with sharing disabled it is a
//                                           no-op that never touches a coordinate.
//                                           Only invoked when BOTH endpoints are
//                                           known (a degenerate origin≈dest pair
//                                           is not recorded).
//   2. PostAlarmMulticast.dispatch       — Guardian "arrived safely" and any
//                                           other post-alarm observers. The
//                                           multicast already runs each listener
//                                           on its own microtask inside its own
//                                           guard.
//   3. MonetizationService.recordRide    — increments the ad-frequency cap
//                                           counter for a completed ride.
library;

import 'dart:async';
import 'dart:developer' as dev;

import 'package:geowake2/services/data_asset/data_asset_pipeline.dart';
import 'package:geowake2/services/monetization/monetization_service.dart';
import 'package:geowake2/services/tracking/post_alarm_multicast.dart';

/// Post-arrival fan-out. Pure static entry point — no state, no lifecycle.
class ArrivalHooks {
  ArrivalHooks._();

  /// Fire the arrival fan-out. MUST be called only after the destination alarm
  /// has fired, been acknowledged, and tracking has been torn down.
  ///
  /// Synchronous and non-throwing by construction: it schedules each sink and
  /// returns immediately. The caller must NOT await it (there is nothing to
  /// await) and must NOT place it before the alarm-stop / teardown.
  ///
  /// All trip descriptors are optional so the call site stays a single line and
  /// so a missing field degrades gracefully (mode → 'unknown', absent coords →
  /// the aggregate surface is simply skipped).
  static void fireArrived({
    String? destStation,
    String? line,
    String? city,
    double? destLat,
    double? destLng,
    double? originLat,
    double? originLng,
    String? mode,
    String outcome = 'onTime',
    bool wokenOnTime = true,
    DateTime? now,
  }) {
    try {
      final ts = now ?? DateTime.now();
      final int epochMs = ts.millisecondsSinceEpoch;

      // (1) Opt-in aggregate mobility surface. Self-gates on consent (default
      // OFF) as its first statement, so this is a no-op unless the rider has
      // explicitly opted in. Only pass through a real, distinct OD pair.
      try {
        if (originLat != null &&
            originLng != null &&
            destLat != null &&
            destLng != null) {
          unawaited(
            DataAssetPipeline.instance.onTripCompleted(
              originLat: originLat,
              originLng: originLng,
              destLat: destLat,
              destLng: destLng,
              epochMs: epochMs,
              tzOffsetMinutes: ts.timeZoneOffset.inMinutes,
            ),
          );
        }
      } catch (_) {/* never matters */}

      // (3) Post-alarm observers (Guardian "arrived safely", etc.). The
      // multicast dispatches each listener on its own microtask inside its own
      // guard — a throwing or hanging listener can neither block us nor starve
      // the others.
      try {
        PostAlarmMulticast.instance.dispatch();
      } catch (_) {/* never matters */}

      // (4) Ad-frequency cap — count this completed ride.
      try {
        unawaited(MonetizationService.instance.recordRide());
      } catch (_) {/* never matters */}
    } catch (e) {
      // Belt-and-suspenders: nothing above can throw synchronously, but if it
      // ever did, swallow it — the wake is long since delivered.
      dev.log('ArrivalHooks.fireArrived swallowed: $e', name: 'ArrivalHooks');
    }
  }
}
