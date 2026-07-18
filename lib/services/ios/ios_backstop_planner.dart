// lib/services/ios/ios_backstop_planner.dart
//
// iOS REACHABILITY BACKSTOP PLANNER (HANDOFF §6).
//
// iOS cannot run an Android-style foreground service and cannot dead-reckon a
// train through a tunnel in the background — the app is suspended. But the
// reachability guarantee gives us something iOS *can* honour while suspended:
// a deterministic EARLIEST-POSSIBLE-ARRIVAL time, pre-computed from route
// distance and the per-line speed ceiling (V_LINE).
//
//     t_earliest = now + (remainingDistance / V_LINE) * 1000ms
//
// Because V_LINE >= the line's true maximum speed (precondition ii of the
// reachability never-late guarantee, see core/reachability/reachability.dart),
// the train CANNOT physically arrive before t_earliest. Scheduling a local
// notification for t_earliest is therefore NEVER-LATE BY PHYSICS: if the train
// actually runs slower than the ceiling (the normal case) the notification
// simply fires early, which is the safe state. This scheduled notification is
// the iOS analogue of the Android exact-alarm backstop.
//
// Alongside the time backstop we emit geofence rings — iOS reliably wakes a
// suspended app on region entry:
//   * a destination ring (fire target), and
//   * an "N stops before" ring (early warning).
//
// This module is PURE and injectable: it does no wall-clock reads (time is
// passed in), imports no iOS/flutter_local_notifications plugin, and drives the
// scheduler through the abstract [IosScheduler] interface so it is fully unit-
// testable headless.

import 'dart:async';
import 'dart:math' as math;

import 'package:geowake2/core/reachability/reachability.dart';

/// A geofence region iOS should monitor. Kept intentionally minimal — the center
/// coordinates are resolved by the platform layer from [id]; this module only
/// represents the ring's identity, radius and role.
class GeofenceRing {
  /// Stable identifier the platform layer uses to resolve the ring's center and
  /// to de-duplicate registrations.
  final String id;

  /// Region radius in meters. iOS enforces a platform minimum (~100 m); callers
  /// supply the radius as an input to [IosBackstopPlanner.plan].
  final double radiusMeters;

  /// Role of this ring: [GeofenceRingKind.destination] or
  /// [GeofenceRingKind.preStop].
  final String kind;

  const GeofenceRing({
    required this.id,
    required this.radiusMeters,
    required this.kind,
  });

  @override
  String toString() =>
      'GeofenceRing(id: $id, radiusMeters: $radiusMeters, kind: $kind)';
}

/// Canonical [GeofenceRing.kind] values.
class GeofenceRingKind {
  /// The fire target — the destination stop we wake for.
  static const String destination = 'destination';

  /// An early-warning ring placed N stops before the destination.
  static const String preStop = 'pre_stop';
}

/// The output of [IosBackstopPlanner.plan]: the scheduled backstop fire time plus
/// the geofence rings to monitor.
class BackstopPlan {
  /// Epoch milliseconds at which the scheduled local notification should fire.
  /// This is the EARLIEST possible arrival (distance / V_LINE) and is guaranteed
  /// to be at or before the true arrival for any train whose speed never exceeds
  /// V_LINE.
  final double earliestArrivalEpochMs;

  /// Geofence rings to register: a destination ring and an "N stops before"
  /// ring.
  final List<GeofenceRing> rings;

  const BackstopPlan({
    required this.earliestArrivalEpochMs,
    required this.rings,
  });
}

/// Injectable seam over the iOS platform primitives (UNUserNotificationCenter +
/// CLLocationManager region monitoring). The concrete implementation lives in
/// the platform layer; this module — and its tests — depend only on this
/// interface so no plugin is imported at module scope.
abstract class IosScheduler {
  /// Schedule a single local notification to fire at [epochMs], keyed by [id].
  Future<void> scheduleLocalNotification(int epochMs, String id);

  /// Begin monitoring [ring] as a geofenced region.
  Future<void> monitorRegion(GeofenceRing ring);
}

/// A record of one scheduled-notification call, for test assertions.
class ScheduledNotification {
  final int epochMs;
  final String id;

  const ScheduledNotification(this.epochMs, this.id);

  @override
  String toString() => 'ScheduledNotification(epochMs: $epochMs, id: $id)';
}

/// In-memory [IosScheduler] that records every call. Test-only; never touches a
/// device or a plugin.
class FakeIosScheduler implements IosScheduler {
  final List<ScheduledNotification> scheduledNotifications =
      <ScheduledNotification>[];
  final List<GeofenceRing> monitoredRegions = <GeofenceRing>[];

  @override
  Future<void> scheduleLocalNotification(int epochMs, String id) async {
    scheduledNotifications.add(ScheduledNotification(epochMs, id));
  }

  @override
  Future<void> monitorRegion(GeofenceRing ring) async {
    monitoredRegions.add(ring);
  }
}

/// Pure planner for the iOS reachability backstop. All methods are static and
/// side-effect free except [arm], which drives an injected [IosScheduler].
class IosBackstopPlanner {
  IosBackstopPlanner._();

  /// Default geofence radii (meters). Tunable per call; iOS clamps to its own
  /// platform minimum.
  static const double defaultDestinationRadiusMeters = 200.0;
  static const double defaultPreStopRadiusMeters = 500.0;

  /// Stable ids for the emitted rings and the scheduled notification.
  static const String destinationRingId = 'geowake_ios_destination';
  static const String preStopRingId = 'geowake_ios_pre_stop';
  static const String backstopNotificationId = 'geowake_ios_backstop';

  /// Build a [BackstopPlan] for the current leg.
  ///
  /// [routeDistanceMeters] is the true track distance of the route (Google
  /// Directions leg distance ≈ decoded-polyline arc length — see HANDOFF §7).
  /// [originProgressMeters], when supplied, is how far along that route the
  /// rider already is; the backstop is computed over the REMAINING distance.
  ///
  /// The V_LINE ceiling is resolved via [VLineTable.forLine] so RRTS / express
  /// services get their (higher) ceiling and therefore an EARLIER — never later
  /// — earliest-arrival than a metro-grade ceiling would give.
  static BackstopPlan plan({
    required double routeDistanceMeters,
    required double nowEpochMs,
    String? city,
    String? lineName,
    double? originProgressMeters,
    VLineTable vLineTable = const VLineTable(),
    double destinationRadiusMeters = defaultDestinationRadiusMeters,
    double preStopRadiusMeters = defaultPreStopRadiusMeters,
    String destinationRingId = IosBackstopPlanner.destinationRingId,
    String preStopRingId = IosBackstopPlanner.preStopRingId,
  }) {
    final double earliestArrivalEpochMs = _earliestArrivalEpochMs(
      routeDistanceMeters: routeDistanceMeters,
      nowEpochMs: nowEpochMs,
      city: city,
      lineName: lineName,
      originProgressMeters: originProgressMeters,
      vLineTable: vLineTable,
    );

    final rings = <GeofenceRing>[
      GeofenceRing(
        id: destinationRingId,
        radiusMeters: _sanitiseRadius(destinationRadiusMeters),
        kind: GeofenceRingKind.destination,
      ),
      GeofenceRing(
        id: preStopRingId,
        radiusMeters: _sanitiseRadius(preStopRadiusMeters),
        kind: GeofenceRingKind.preStop,
      ),
    ];

    return BackstopPlan(
      earliestArrivalEpochMs: earliestArrivalEpochMs,
      rings: List<GeofenceRing>.unmodifiable(rings),
    );
  }

  /// Drive [scheduler] from [plan]: schedule exactly one backstop notification at
  /// the earliest-arrival time, then register every ring for region monitoring.
  static Future<void> arm(BackstopPlan plan, IosScheduler scheduler) async {
    // Isolate every arming call: the time backstop and each geofence ring are
    // INDEPENDENT safety nets, so one failing must NEVER prevent the others from
    // arming. A single unhandled throw here would mean "one failure => never
    // fires" — the cardinal sin for a wake alarm.
    try {
      await scheduler.scheduleLocalNotification(
        _toEpochInt(plan.earliestArrivalEpochMs),
        backstopNotificationId,
      );
    } catch (_) {/* time backstop failed; the geofence rings may still wake them */}
    for (final ring in plan.rings) {
      try {
        await scheduler.monitorRegion(ring);
      } catch (_) {/* this ring failed; keep arming the remaining rings */}
    }
  }

  /// Earliest-possible arrival: `now + (remaining / V_LINE) * 1000`.
  ///
  /// Every guard falls to the NEVER-LATE side: a non-finite / non-positive
  /// V_LINE falls back to the absolute ceiling (faster → earlier → safe), and a
  /// non-finite / already-covered distance yields `now` (fire immediately →
  /// safe). Because V_LINE >= true max speed, the returned time is <= the true
  /// arrival for any admissible trajectory.
  static double _earliestArrivalEpochMs({
    required double routeDistanceMeters,
    required double nowEpochMs,
    required String? city,
    required String? lineName,
    required double? originProgressMeters,
    required VLineTable vLineTable,
  }) {
    final double vRaw = vLineTable.forLine(city: city, lineName: lineName);
    // A higher ceiling only makes us EARLIER, so an invalid ceiling safely
    // overbounds to the absolute ceiling rather than risking a late fire.
    final double vLine = (vRaw.isFinite && vRaw > 0)
        ? vRaw
        : VLineTable.absoluteCeilingMps;

    final double now = nowEpochMs.isFinite ? nowEpochMs : 0.0;

    if (!routeDistanceMeters.isFinite) {
      // Unknown distance: fire immediately rather than never.
      return now;
    }

    final double progressed = (originProgressMeters != null &&
            originProgressMeters.isFinite &&
            originProgressMeters > 0)
        ? originProgressMeters
        : 0.0;

    final double remaining = math.max(0.0, routeDistanceMeters - progressed);
    final double travelMs = (remaining / vLine) * 1000.0;
    return now + travelMs;
  }

  static double _sanitiseRadius(double r) =>
      (r.isFinite && r > 0) ? r : defaultDestinationRadiusMeters;

  /// Convert the double epoch to the int the scheduler expects. Floor (rather
  /// than round) so any sub-millisecond remainder pulls the fire time EARLIER,
  /// preserving the never-late property.
  static int _toEpochInt(double epochMs) {
    if (!epochMs.isFinite) return 0;
    return epochMs.floor();
  }
}
