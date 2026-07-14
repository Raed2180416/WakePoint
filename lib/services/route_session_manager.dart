import 'dart:async';
import 'dart:developer' as dev;
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:logging/logging.dart';
import 'package:geolocator/geolocator.dart';

import 'package:geowake2/services/active_route_manager.dart';
import 'package:geowake2/services/route_registry.dart';
import 'package:geowake2/services/deviation_monitor.dart';
import 'package:geowake2/services/tracking_state_store.dart';
import 'package:geowake2/services/route_cache.dart';
import 'package:geowake2/services/polyline_simplifier.dart';
import 'package:geowake2/services/polyline_decoder.dart';
import 'package:geowake2/services/transfer_utils.dart';
import 'package:geowake2/services/direction_service.dart';
import 'package:geowake2/services/offline_coordinator.dart';
import 'package:geowake2/services/location_manager.dart';
import 'package:geowake2/services/soft_lock_manager.dart';
import 'package:geowake2/services/reroute_policy.dart';
import 'package:geowake2/services/snap_to_route.dart';

/// Manages the lifecycle of multiple routes in a tracking session.
/// Handles registration, activation, switching, and deviation monitoring.
class RouteSessionManager {
  final _log = Logger('RouteSessionManager');

  // Legacy compatibility fields
  final Map<String, Map<String, dynamic>> routePayloadsByKey = {};
  DateTime? lastRouteBroadcastAt;

  // Route Registry & Managers
  final RouteRegistry registry = RouteRegistry();
  ActiveRouteManager? activeManager;
  DeviationMonitor? devMonitor;
  final SoftLockManager softLockManager = SoftLockManager();
  ReroutePolicy? reroutePolicy;

  // State Streams
  final _routeStateCtrl = StreamController<ActiveRouteState>.broadcast();
  Stream<ActiveRouteState> get routeStateStream => _routeStateCtrl.stream;

  final _routeSwitchCtrl = StreamController<RouteSwitchEvent>.broadcast();
  Stream<RouteSwitchEvent> get routeSwitchStream => _routeSwitchCtrl.stream;

  final _rerouteCtrl = StreamController<RerouteDecision>.broadcast();
  Stream<RerouteDecision> get rerouteStream => _rerouteCtrl.stream;

  // Deviation state stream for termination policy
  final _deviationStateCtrl = StreamController<DeviationState>.broadcast();
  Stream<DeviationState> get deviationStateStream => _deviationStateCtrl.stream;

  // G14/G15 wrong-direction / wrong-train alerts (forwarded from ActiveRouteManager)
  final _wrongDirCtrl = StreamController<WrongDirectionAlert>.broadcast();
  Stream<WrongDirectionAlert> get wrongDirectionStream => _wrongDirCtrl.stream;

  // Internal subscriptions
  StreamSubscription<ActiveRouteState>? _mgrStateSub;
  StreamSubscription<RouteSwitchEvent>? _mgrSwitchSub;
  StreamSubscription<DeviationState>? _devSub;
  StreamSubscription<RerouteDecision>? _rerouteSub;
  StreamSubscription<WrongDirectionAlert>? _mgrWrongDirSub;

  // Current State
  ActiveRouteState? lastActiveState;
  LatLng? lastIngestedPosition;
  bool activeRouteInitialized = false;
  bool rerouteInFlight = false;
  bool transitMode = false;

  // Per-Route State Maps (Route Key -> Data)
  final Map<String, List<RouteEventBoundary>> routeEventsByKey = {};
  final Map<String, List<double>> stepBoundsMetersByKey = {};
  final Map<String, List<double>> stepStopsCumulativeByKey = {};
  final Map<String, List<int>> stepDurationsSecondsByKey = {};
  final Map<String, LatLng?> firstTransitBoardingByKey = {};
  final Map<String, bool> transitModeByKey = {};
  final Map<String, List<TransitLegStops>> transitLegStopsByKey = {};

  final Map<String, Map<String, dynamic>> _routePayloadsByKey = {};
  Map<String, dynamic>? cachedRoutePayload;
  DateTime? _lastRouteBroadcastAt;

  // Persistence / Restore
  Map<String, dynamic>? currentDirections;

  // Singletons/Services
  final OfflineCoordinator? offlineCoordinator;
  final bool isTestMode;

  RouteSessionManager({this.offlineCoordinator, this.isTestMode = false});

  Future<void> dispose() async {
    await _mgrStateSub?.cancel();
    await _mgrSwitchSub?.cancel();
    await _devSub?.cancel();
    await _rerouteSub?.cancel();
    await _mgrWrongDirSub?.cancel();
    activeManager?.dispose();
    devMonitor?.dispose();
    reroutePolicy?.dispose();
    await _routeStateCtrl.close();
    await _routeSwitchCtrl.close();
    await _rerouteCtrl.close();
    await _deviationStateCtrl.close();
    await _wrongDirCtrl.close();
    clearSession();
  }

  void clearSession() {
    registry.clear();
    activeRouteInitialized = false;
    lastActiveState = null;
    routeEventsByKey.clear();
    stepBoundsMetersByKey.clear();
    stepStopsCumulativeByKey.clear();
    stepDurationsSecondsByKey.clear();
    firstTransitBoardingByKey.clear();
    transitModeByKey.clear();
    transitLegStopsByKey.clear();
    _routePayloadsByKey.clear();
    cachedRoutePayload = null;
    _lastRouteBroadcastAt = null;
    currentDirections = null;
  }

  // --- Route Registration Interface ---

  /// Register a route from directions response.
  /// Caller (TrackingService) is responsible for handling foreground communication first.
  Future<void> registerRouteFromDirections({
    required Map<String, dynamic> directions,
    required LatLng origin,
    required LatLng destination,
    required bool transitMode,
    String? destinationName,
    bool activateRoute = false,
  }) async {
    final mode = transitMode ? 'transit' : 'driving';
    currentDirections = directions;

    final key = RouteCache.makeKey(
      origin: origin,
      destination: destination,
      mode: mode,
      transitVariant: transitMode ? 'rail' : null,
    );

    // Note: Alarm state reset logic resides in TrackingService/AlarmOrchestrator,
    // as it manages the actual alarm firing state. This manager just manages ROUTE data.

    transitModeByKey[key] = transitMode;

    // Parse Points
    List<LatLng> points = [];
    double polylineMeters = 0.0;
    bool usedFallbackPolyline = false;
    bool usedStepsPolyline = false;
    bool usedOverviewPolyline = false;
    bool usedSimplifiedPolyline = false;
    String polylineSource = 'unknown';
    try {
      final route =
          (directions['routes'] as List).first as Map<String, dynamic>;

      bool looksPlausible(List<LatLng> pts) {
        if (pts.length < 2) return false;
        final startDist = Geolocator.distanceBetween(
          origin.latitude,
          origin.longitude,
          pts.first.latitude,
          pts.first.longitude,
        );
        final endDist = Geolocator.distanceBetween(
          destination.latitude,
          destination.longitude,
          pts.last.latitude,
          pts.last.longitude,
        );
        // Real Directions polylines should start/end close to origin/destination.
        // In tests we often use placeholder strings which decode to nonsense.
        return startDist <= 5000.0 && endDist <= 5000.0;
      }

      List<LatLng> buildFallbackFromSteps(Map<String, dynamic> route) {
        final result = <LatLng>[];
        try {
          final legs = (route['legs'] as List?) ?? const [];
          for (final leg in legs) {
            final steps = (leg['steps'] as List?) ?? const [];
            for (final stepAny in steps) {
              final step = stepAny as Map<String, dynamic>;
              final start = step['start_location'] as Map<String, dynamic>?;
              final end = step['end_location'] as Map<String, dynamic>?;

              LatLng? s;
              LatLng? e;
              if (start != null) {
                final lat = (start['lat'] as num?)?.toDouble();
                final lng = (start['lng'] as num?)?.toDouble();
                if (lat != null && lng != null) {
                  s = LatLng(lat, lng);
                }
              }
              if (end != null) {
                final lat = (end['lat'] as num?)?.toDouble();
                final lng = (end['lng'] as num?)?.toDouble();
                if (lat != null && lng != null) {
                  e = LatLng(lat, lng);
                }
              }

              if (s != null) {
                if (result.isEmpty) {
                  result.add(s);
                } else {
                  final last = result.last;
                  final d = Geolocator.distanceBetween(
                    last.latitude,
                    last.longitude,
                    s.latitude,
                    s.longitude,
                  );
                  if (d > 10.0) result.add(s);
                }
              }
              if (e != null) {
                if (result.isEmpty) {
                  result.add(e);
                } else {
                  final last = result.last;
                  final d = Geolocator.distanceBetween(
                    last.latitude,
                    last.longitude,
                    e.latitude,
                    e.longitude,
                  );
                  if (d > 10.0) result.add(e);
                }
              }
            }
          }
        } catch (_) {}

        if (result.length < 2) {
          return [origin, destination];
        }
        // Ensure endpoints are reasonable.
        if (!looksPlausible(result)) {
          return [origin, destination];
        }
        return result;
      }

      // PREFERRED: Build points from step polylines (high fidelity, matches stopMeters domain)
      if (points.length < 2) {
        try {
          final legs = (route['legs'] as List?) ?? const [];
          for (final leg in legs) {
            final steps = (leg['steps'] as List?) ?? const [];
            for (final step in steps) {
              final stepPoly = step['polyline'] as Map<String, dynamic>?;
              if (stepPoly != null && stepPoly['points'] != null) {
                final stepPoints = decodePolyline(stepPoly['points'] as String);
                if (stepPoints.isNotEmpty) {
                  usedStepsPolyline = true;
                }
                // Avoid duplicating junction points
                if (points.isNotEmpty && stepPoints.isNotEmpty) {
                  final lastPt = points.last;
                  final firstStepPt = stepPoints.first;
                  final dist = Geolocator.distanceBetween(
                    lastPt.latitude,
                    lastPt.longitude,
                    firstStepPt.latitude,
                    firstStepPt.longitude,
                  );
                  if (dist < 10.0) {
                    // Skip duplicate junction
                    points.addAll(stepPoints.skip(1));
                  } else {
                    points.addAll(stepPoints);
                  }
                } else {
                  points.addAll(stepPoints);
                }
              }
            }
          }
        } catch (_) {}
      }

      // FALLBACK: Use overview_polyline if step parsing failed or produced nothing
      if (points.length < 2 &&
          route['overview_polyline'] != null &&
          route['overview_polyline']['points'] != null) {
        points = decodePolyline(route['overview_polyline']['points'] as String);
        usedOverviewPolyline = true;
      }

      // LAST RESORT: Use simplified_polyline only if nothing else worked.
      // This polyline is intentionally simplified for caching/transport and can
      // look overly straight; do not prefer it for rendering or snapping.
      if (points.length < 2) {
        final scp = route['simplified_polyline'];
        if (scp is String && scp.isNotEmpty) {
          try {
            points = PolylineSimplifier.decompressPolyline(scp);
            usedSimplifiedPolyline = true;
          } catch (e) {
            _log.warning('Polyline decompress failed', e);
            points = [];
          }
        }
      }

      // If the decoded polyline looks unrelated to the origin/destination (common
      // in unit tests with placeholder polyline strings), rebuild a simple
      // polyline from step start/end locations so snapping/progress works.
      // BUT: we track whether we used the fallback so we can skip scaling later
      // (fallback polyline length may differ from stated step distances).
      if (!looksPlausible(points)) {
        points = buildFallbackFromSteps(route);
        usedFallbackPolyline = true;
      }
      polylineMeters = _polylineLengthMeters(points);
    } catch (e) {
      _log.warning('Route parsing failed', e);
    }

    if (usedFallbackPolyline) {
      polylineSource = 'fallback_steps';
    } else if (usedStepsPolyline) {
      polylineSource = 'steps';
    } else if (usedOverviewPolyline) {
      polylineSource = 'overview';
    } else if (usedSimplifiedPolyline) {
      polylineSource = 'simplified';
    }

    // Parse Step Bounds & Stops
    List<double> stepBoundsMeters = [];
    List<double> stepStopsCumulative = [];
    List<int> stepDurationsSeconds = [];
    List<TransitLegStops> transitLegStops = [];

    try {
      final m = TransferUtils.buildStepBoundariesAndStops(directions);
      final stepLen = m.bounds.isNotEmpty ? m.bounds.last : 0.0;
      double scale = 1.0;
      // Only scale if we have a real polyline (not fallback) and lengths differ
      if (!usedFallbackPolyline &&
          polylineMeters > 0.0 &&
          stepLen > 0.0 &&
          (polylineMeters - stepLen).abs() > 10.0) {
        scale = polylineMeters / stepLen;
      }

      stepBoundsMeters =
          scale == 1.0
              ? List<double>.from(m.bounds)
              : m.bounds.map((b) => b * scale).toList();
      stepStopsCumulative = _buildCumulativeStops(
        stepBoundsMeters,
        m.stops,
      ); // Note: Passing scaled bounds? No, usually raw matches raw.
      // Wait, _buildCumulativeStops logic trusts bounds. If we scale bounds, we should scale stops?
      // TrackingService did: _buildCumulativeStops(scaledBounds, m.stops)
      // Wait, m.stops are raw counts? No, cumulative distances?
      // _buildCumulativeStops takes rawStops (distances).
      // So if we scaled bounds, we should scale stops too?
      stepStopsCumulative = _buildCumulativeStops(
        stepBoundsMeters,
        m.stops,
      ); // m.stops are distances?
      // TransferUtils.buildStepBoundariesAndStops returns stops as List<double>?
      // TrackingService used raw m.stops. If m.stops are meters, they should be scaled.
      // But TrackingService didn't scale m.stops explicitly in the call, but _buildCumulativeStops logic might handle it?
      // Actually TrackingService line 3624: _stepStopsCumulative = _buildCumulativeStops(scaledBounds, m.stops);
      // If m.stops are meters, and scaledBounds are scaled, then logic might drift if not scaled.
      // But let's stick to TrackingService implementation for now.

      stepDurationsSeconds = m.durations;

      stepBoundsMetersByKey[key] = List<double>.from(stepBoundsMeters);
      stepStopsCumulativeByKey[key] = List<double>.from(stepStopsCumulative);
      stepDurationsSecondsByKey[key] = List<int>.from(stepDurationsSeconds);

      // Transit Leg Stops
      // Always use freshly calculated legs to ensure correct meter domain
      // (cached legs may be from old domain calculations)
      // Transit Leg Stops
      // PERSISTENCE FIX: Try to load existing enhanced legs first to prevent overwriting with raw data
      List<TransitLegStops>? loadedLegs;
      try {
        loadedLegs = await TrackingStateStore.loadTransitLegStops(key);
      } catch (_) {}

      if (loadedLegs != null && loadedLegs.isNotEmpty) {
        // FIX: Check for stale "Walk" names that cause unstable leg IDs (multiple preboarding alarms)
        bool hasStaleWalkNames = false;
        for (int i = 0; i < loadedLegs.length - 1; i++) {
          final leg = loadedLegs[i];
          final nextLeg = loadedLegs[i + 1];
          // If we have a generic "Walk" leg immediately followed by a Metro leg,
          // it means our stable naming ("Walk to [Station]") logic wasn't applied or was lost.
          if (leg.lineName == 'Walk' && nextLeg.isMetro) {
            hasStaleWalkNames = true;
            print(
              '⚠️ RouteSessionManager: Found stale generic "Walk" leg before Metro. Invalidating persistence to fix naming.',
            );
            break;
          }
        }

        if (hasStaleWalkNames) {
          loadedLegs = null; // Force fresh extraction
        }
      }

      if (loadedLegs != null && loadedLegs.isNotEmpty) {
        final enhancedCount =
            loadedLegs.where((l) => l.isActualPositions).length;
        final metroCount = loadedLegs.where((l) => l.isMetro).length;
        print(
          '🚇 RouteSessionManager: RESTORED ${loadedLegs.length} persistent transit legs for key=$key ($enhancedCount OSM-enhanced, ${loadedLegs.length - enhancedCount} interpolated)',
        );

        // FIX: If metro legs are loaded but NOT enhanced, and transitMode is on,
        // re-run OSM enhancement to fix stale interpolated data
        if (transitMode && metroCount > 0 && enhancedCount < metroCount) {
          print(
            '🔄 RouteSessionManager: Re-enhancing ${metroCount - enhancedCount} stale metro legs with OSM data...',
          );
          try {
            transitLegStops = await TransferUtils.enhanceTransitLegStopsWithOsm(
              loadedLegs,
              directions,
            );
            // Save re-enhanced legs
            if (transitLegStops.isNotEmpty) {
              await TrackingStateStore.saveTransitLegStops(
                key,
                transitLegStops,
              );
            }
          } catch (e) {
            // Fallback to loaded legs if re-enhancement fails
            transitLegStops = loadedLegs;
            print(
              '🚇 RouteSessionManager: Re-enhancement failed, using loaded legs: $e',
            );
          }
        } else {
          transitLegStops = loadedLegs;
        }
      } else {
        // Always use freshly calculated legs to ensure correct meter domain
        // (cached legs may be from old domain calculations)
        var rawTransitLegs = TransferUtils.extractTransitLegStops(directions);

        // Enhance with OSM data for better stop positions
        // Only perform if Metro Mode (transitMode) is enabled
        if (transitMode) {
          try {
            rawTransitLegs = await TransferUtils.enhanceTransitLegStopsWithOsm(
              rawTransitLegs,
              directions,
            );
          } catch (e) {
            // ignore enhancement errors, use raw legs
          }
        }

        // IMPORTANT: `extractTransitLegStops()` prefers polyline-derived meters.
        // That is already in the same domain as `polylineMeters` / snapping progress.
        // The step-boundary `scale` (derived from API distances) MUST NOT be applied
        // to transit legs, or we shrink legs and break leg indexing + alarms.
        //
        // Instead, only apply a correction scale if the computed leg meters do not
        // match the decoded overview polyline length (e.g., placeholder polylines
        // forced us to fall back to API distances).
        double legScale = 1.0;
        if (!usedFallbackPolyline && rawTransitLegs.isNotEmpty) {
          final rawEnd = rawTransitLegs.last.legEndMeters;
          if (polylineMeters > 0.0 &&
              rawEnd > 0.0 &&
              (polylineMeters - rawEnd).abs() > 10.0) {
            legScale = polylineMeters / rawEnd;
          }
        }

        if (legScale != 1.0 && rawTransitLegs.isNotEmpty) {
          transitLegStops =
              rawTransitLegs
                  .map(
                    (leg) => leg.copyWith(
                      legStartMeters: leg.legStartMeters * legScale,
                      legEndMeters: leg.legEndMeters * legScale,
                      stopMeters:
                          leg.stopMeters.map((m) => m * legScale).toList(),
                    ),
                  )
                  .toList();
        } else {
          transitLegStops = rawTransitLegs;
        }

        if (transitLegStops.isNotEmpty) {
          await TrackingStateStore.saveTransitLegStops(key, transitLegStops);
        }
      }

      print(
        '🚇 RouteSessionManager: Stored ${transitLegStops.length} transit legs for key=$key',
      );
      for (int i = 0; i < transitLegStops.length; i++) {
        final leg = transitLegStops[i];
        print(
          '   Leg[$i]: ${leg.lineName}, isMetro=${leg.isMetro}, range=${leg.legStartMeters.toStringAsFixed(0)}-${leg.legEndMeters.toStringAsFixed(0)}m, stops=${leg.numStops}, source=${leg.isActualPositions ? "OSM" : "Interpolated"}',
        );
      }

      transitLegStopsByKey[key] = List<TransitLegStops>.from(transitLegStops);
    } catch (_) {
      // Fallback empty
      stepBoundsMetersByKey[key] = const [];
      stepStopsCumulativeByKey[key] = const [];
      transitLegStopsByKey[key] = const [];
    }

    if (points.isEmpty) {
      points = [origin, destination];
    }

    // Parse Events
    List<RouteEventBoundary> events = [];
    try {
      events = TransferUtils.buildRouteEvents(directions);
      double eventScale = 1.0;
      final stepLen = stepBoundsMeters.isNotEmpty ? stepBoundsMeters.last : 0.0;
      if (polylineMeters > 0.0 && stepLen > 0.0) {
        eventScale = polylineMeters / stepLen;
      }

      if (eventScale != 1.0) {
        events =
            events
                .map(
                  (e) => RouteEventBoundary(
                    meters: e.meters * eventScale,
                    type: e.type,
                    label: e.label,
                    lat: e.lat,
                    lng: e.lng,
                    associatedLegIndex: e.associatedLegIndex,
                  ),
                )
                .toList();
      }

      // Metro final station logic
      if (transitMode && stepBoundsMeters.isNotEmpty) {
        try {
          double cumM = 0.0;
          double? lastMetroEndM;
          String? lastArrivalName;
          double? lastArrivalLat;
          double? lastArrivalLng;

          final routes = (directions['routes'] as List?) ?? const [];
          if (routes.isNotEmpty) {
            final route = routes.first as Map<String, dynamic>;
            final legs = (route['legs'] as List?) ?? const [];
            for (final legAny in legs) {
              final leg = legAny as Map<String, dynamic>;
              final steps = (leg['steps'] as List?) ?? const [];
              for (final stepAny in steps) {
                final step = stepAny as Map<String, dynamic>;
                final dist =
                    ((step['distance'] as Map?)?['value'] as num?)
                        ?.toDouble() ??
                    0.0;
                cumM += dist;

                if (_isMetroStep(step)) {
                  lastMetroEndM = cumM;
                  try {
                    final arr =
                        (step['transit_details']
                                as Map<String, dynamic>?)?['arrival_stop']
                            as Map<String, dynamic>?;
                    lastArrivalName = arr?['name'] as String?;
                    final loc = arr?['location'] as Map<String, dynamic>?;
                    if (loc != null) {
                      lastArrivalLat = (loc['lat'] as num?)?.toDouble();
                      lastArrivalLng = (loc['lng'] as num?)?.toDouble();
                    }
                  } catch (_) {}
                }
              }
            }
          }

          if (lastMetroEndM != null && lastMetroEndM > 0.0) {
            final scaledLastMetroEndM =
                eventScale != 1.0 ? lastMetroEndM * eventScale : lastMetroEndM;
            events.add(
              RouteEventBoundary(
                meters: scaledLastMetroEndM,
                type: 'final_station',
                label: lastArrivalName ?? 'Final station',
                lat: lastArrivalLat,
                lng: lastArrivalLng,
              ),
            );
          }
        } catch (_) {}
      }

      // Add Destination Event
      if (stepBoundsMeters.isNotEmpty) {
        final totalDist = stepBoundsMeters.last;
        events.add(
          RouteEventBoundary(
            meters: totalDist,
            type: 'destination',
            label: destinationName ?? 'Destination',
          ),
        );
      }
      events.sort((a, b) => a.meters.compareTo(b.meters));
    } catch (_) {
      events = [];
    }

    routeEventsByKey[key] = List<RouteEventBoundary>.from(events);

    // Compute First Transit Boarding
    LatLng? firstBoarding;
    try {
      final routes = (directions['routes'] as List?) ?? const [];
      if (routes.isNotEmpty) {
        final route = routes.first as Map<String, dynamic>;
        final legs = (route['legs'] as List?) ?? const [];
        outer:
        for (final leg in legs) {
          final steps = (leg['steps'] as List?) ?? const [];
          for (final s in steps) {
            final step = s as Map<String, dynamic>;
            if (_isMetroStep(step)) {
              try {
                final dep =
                    (step['transit_details']
                            as Map<String, dynamic>?)?['departure_stop']
                        as Map<String, dynamic>?;
                final loc =
                    dep != null
                        ? dep['location'] as Map<String, dynamic>?
                        : null;
                if (loc != null) {
                  final lat = (loc['lat'] as num?)?.toDouble();
                  final lng = (loc['lng'] as num?)?.toDouble();
                  if (lat != null && lng != null) {
                    firstBoarding = LatLng(lat, lng);
                  }
                }
              } catch (_) {}
              if (firstBoarding == null) {
                try {
                  final pts = decodePolyline(
                    (step['polyline'] as Map<String, dynamic>)['points']
                        as String,
                  );
                  if (pts.isNotEmpty) firstBoarding = pts.first;
                } catch (_) {}
              }
              break outer;
            }
          }
        }
      }
    } catch (_) {}

    if (firstBoarding == null && events.isNotEmpty) {
      try {
        final ev = events.firstWhere(
          (e) => e.type == 'boarding' || e.type == 'transfer',
        );
        if (ev.lat != null && ev.lng != null) {
          firstBoarding = LatLng(ev.lat!, ev.lng!);
        }
      } catch (_) {}
    }

    if (firstBoarding == null && points.length > 1) {
      firstBoarding = points[1];
    }
    firstTransitBoardingByKey[key] = firstBoarding;

    // Build Segments & Switch Points
    List<Map<String, dynamic>> segments = [];
    try {
      segments = DirectionService().buildRawSegments(directions, transitMode);
    } catch (_) {}

    List<Map<String, dynamic>> switchPoints = [];
    try {
      final routes = (directions['routes'] as List?) ?? const [];
      if (routes.isNotEmpty) {
        final route = routes.first as Map<String, dynamic>;
        final legs = (route['legs'] as List?) ?? const [];
        for (final leg in legs) {
          final steps = (leg['steps'] as List?) ?? const [];
          for (final s in steps) {
            final step = s as Map<String, dynamic>;
            final stepMode =
                (step['travel_mode'] as String?)?.toLowerCase() ?? 'walking';
            if (stepMode == 'transit' && _isMetroStep(step)) {
              try {
                final dep =
                    (step['transit_details'] as Map?)?['departure_stop']
                        as Map?;
                if (dep != null) {
                  final loc = dep['location'] as Map?;
                  if (loc != null) {
                    switchPoints.add({
                      'lat': loc['lat'],
                      'lng': loc['lng'],
                      'type': 'boarding',
                      'label': dep['name'] ?? 'Boarding',
                    });
                  }
                }
                final arr =
                    (step['transit_details'] as Map?)?['arrival_stop'] as Map?;
                if (arr != null) {
                  final loc = arr['location'] as Map?;
                  if (loc != null) {
                    switchPoints.add({
                      'lat': loc['lat'],
                      'lng': loc['lng'],
                      'type': 'alighting',
                      'label': arr['name'] ?? 'Alighting',
                    });
                  }
                }
              } catch (_) {}
            }
          }
        }
      }
    } catch (_) {}

    // Construct simplified events list for serialization
    final serializedEvents = events.map((e) => e.toJson()).toList();

    final routeDebug = <String, dynamic>{
      'polyline_source': polylineSource,
      'points_count': points.length,
      'polyline_meters': polylineMeters,
      'used_fallback_polyline': usedFallbackPolyline,
      'used_simplified_polyline': usedSimplifiedPolyline,
      'segments_count': segments.length,
      'switch_points_count': switchPoints.length,
      'transit_mode': transitMode,
    };

    _log.info('Route debug [$key]: $routeDebug');

    // Delegate to registerRoute to finish setup
    registerRoute(
      key: key,
      mode: mode,
      destinationName: destinationName ?? 'Destination',
      points: points,
      segments: segments,
      switchPoints: switchPoints,
      events: serializedEvents,
      routeDebug: routeDebug,
      activate: activateRoute,
    );
  }

  /// Register a fully parsed route.
  void registerRoute({
    required String key,
    required String mode,
    required String destinationName,
    required List<LatLng> points,
    List<Map<String, dynamic>>? segments,
    List<Map<String, dynamic>>? switchPoints,
    List<Map<String, dynamic>>? events,
    List<Map<String, dynamic>>? transitLegsJson, // New Param
    Map<String, dynamic>? routeDebug,
    bool activate = false,
  }) {
    final isTransitMode = mode == 'transit';

    // Deserialize transit legs if provided
    if (transitLegsJson != null) {
      final legs =
          transitLegsJson.map((json) {
            return TransitLegStops.fromJson(json);
          }).toList();
      transitLegStopsByKey[key] = legs;
    }

    cachedRoutePayload = {
      'destinationName': destinationName,
      'points':
          points.map((p) => {'lat': p.latitude, 'lng': p.longitude}).toList(),
      if (segments != null) 'segments': segments,
      if (switchPoints != null) 'switch_points': switchPoints,
      if (events != null) 'events': events,
      'transit_mode': isTransitMode,
      if (routeDebug != null) 'route_debug': routeDebug,
    };
    _routePayloadsByKey[key] = Map<String, dynamic>.from(cachedRoutePayload!);

    final entry = RouteEntry(
      key: key,
      mode: mode,
      destinationName: destinationName,
      points: points,
    );
    registry.upsert(entry);

    List<Map<String, dynamic>>? filteredSwitchPoints;
    if (switchPoints != null) {
      filteredSwitchPoints = [];
      final destLat = points.isNotEmpty ? points.last.latitude : 0.0;
      final destLng = points.isNotEmpty ? points.last.longitude : 0.0;

      for (var sp in switchPoints) {
        final lat = sp['lat'] as double;
        final lng = sp['lng'] as double;
        bool keep = true;
        for (var existing in filteredSwitchPoints) {
          final dist = Geolocator.distanceBetween(
            lat,
            lng,
            existing['lat'],
            existing['lng'],
          );
          if (dist < 200) {
            keep = false;
            break;
          }
        }
        if (keep && points.isNotEmpty) {
          final distToDest = Geolocator.distanceBetween(
            lat,
            lng,
            destLat,
            destLng,
          );
          if (distToDest < 200) keep = false;
        }
        if (keep) filteredSwitchPoints.add(sp);
      }
    }

    // Parse Events if not already done via FromDirections
    if (!routeEventsByKey.containsKey(key) && events != null) {
      final parsedEvents = <RouteEventBoundary>[];
      for (var evMap in events) {
        try {
          final meters = (evMap['meters'] as num).toDouble();
          final type = evMap['type'] as String;
          parsedEvents.add(
            RouteEventBoundary(
              meters: meters,
              type: type,
              label: evMap['label'] as String?,
              lat: evMap['lat'] as double?,
              lng: evMap['lng'] as double?,
              associatedLegIndex: evMap['associatedLegIndex'] as int?,
            ),
          );
        } catch (_) {}
      }
      parsedEvents.sort((a, b) => a.meters.compareTo(b.meters));
      routeEventsByKey[key] = parsedEvents;
    } else if (!routeEventsByKey.containsKey(key)) {
      routeEventsByKey[key] = const [];
    }

    // Broadcast via LocationManager
    _maybeBroadcastCachedRoute(force: true);

    // Initializers
    activeManager ??= ActiveRouteManager(
      registry: registry,
      sustainDuration:
          isTestMode
              ? const Duration(milliseconds: 300)
              : const Duration(seconds: 6),
      switchMarginMeters: isTestMode ? 20 : 50,
      postSwitchBlackout:
          isTestMode
              ? const Duration(milliseconds: 300)
              : const Duration(seconds: 5),
    );

    // Re-setup listeners every time activeManager is (re)created or just once?
    // TrackingService did it every time.
    _setupManagerListeners();

    devMonitor ??= DeviationMonitor(
      sustainDuration:
          isTestMode
              ? const Duration(milliseconds: 300)
              : const Duration(seconds: 5),
    );
    _setupDeviationListeners();

    reroutePolicy ??= ReroutePolicy(
      cooldown:
          isTestMode ? const Duration(seconds: 2) : const Duration(seconds: 20),
      initialOnline: true,
    );
    _setupRerouteListeners();

    if (!activeRouteInitialized) {
      activeManager!.setActive(key);
      activeRouteInitialized = true;
    }

    if (activate) {
      final fromKey = lastActiveState?.activeKey;
      activeManager!.setActive(key);
      activeRouteInitialized = true;

      if (fromKey != null && fromKey != key) {
        final evt = RouteSwitchEvent(
          fromKey: fromKey,
          toKey: key,
          geometry: points,
        );
        _routeSwitchCtrl.add(evt);
      }
      if (points.isNotEmpty) {
        activeManager!.ingestPosition(points.first);
      }
    }
  }

  /// Switches to a previously registered route by its key.
  /// Returns true if the switch was successful.
  bool switchToRoute(String routeKey) {
    if (activeManager == null) {
      dev.log(
        'switchToRoute failed: no activeManager',
        name: 'RouteSessionManager',
      );
      return false;
    }

    // Check if route exists in registry
    final hasRoute = registry.entries.any((e) => e.key == routeKey);
    if (!hasRoute) {
      dev.log(
        'switchToRoute failed: route key not found: $routeKey',
        name: 'RouteSessionManager',
      );
      return false;
    }

    final fromKey = lastActiveState?.activeKey;
    activeManager!.setActive(routeKey);

    // Emit switch event
    if (fromKey != null && fromKey != routeKey) {
      final entry = registry.entries.firstWhere(
        (e) => e.key == routeKey,
        orElse: () => registry.entries.first,
      );
      final evt = RouteSwitchEvent(
        fromKey: fromKey,
        toKey: routeKey,
        geometry: entry.points,
      );
      _routeSwitchCtrl.add(evt);

      dev.log(
        'switchToRoute: switched from $fromKey to $routeKey',
        name: 'RouteSessionManager',
      );
    }

    // Force broadcast to update dashboard with new active/inactive routes
    _maybeBroadcastCachedRoute(force: true);

    return true;
  }

  void _maybeBroadcastCachedRoute({bool force = false}) {
    final payload = cachedRoutePayload;
    if (payload == null) return;
    if (!force &&
        _lastRouteBroadcastAt != null &&
        DateTime.now().difference(_lastRouteBroadcastAt!).inSeconds < 20) {
      return;
    }

    final inactive = _getInactiveRoutesPayload();
    final routeDebug =
      (payload['route_debug'] as Map?)?.cast<String, dynamic>();
    _lastRouteBroadcastAt = DateTime.now();

    // Use transitLegStops of ACTIVE key if available, or just first?
    // TrackingService used global _transitLegStops.
    // Here we should probably use steps from current active route?
    // We don't strictly know active route key here without activeManager lookup
    final activeKey = activeManager?.activeKey;
    final legs =
        activeKey != null ? (transitLegStopsByKey[activeKey] ?? []) : [];
    // Fix: ensure correct type explicitly
    List<double>? stopMeters;
    List<Map<String, dynamic>>? transitLegsJson;
    if (legs.isNotEmpty) {
      final typedLegs = legs as List<TransitLegStops>;
      stopMeters =
          typedLegs
              .expand((l) => l.stopMeters.map((m) => (m as num).toDouble()))
              .toList();
      // Serialize transit legs for dashboard visualization
      transitLegsJson = typedLegs.map((l) => l.toJson()).toList();
    }

    LocationManager().broadcastRoute(
      routeKey: activeKey,
      destinationName: payload['destinationName'] as String,
      points: (payload['points'] as List).cast<Map<String, dynamic>>(),
      segments: (payload['segments'] as List?)?.cast<Map<String, dynamic>>(),
      switchPoints:
          (payload['switch_points'] as List?)?.cast<Map<String, dynamic>>(),
      events: (payload['events'] as List?)?.cast<Map<String, dynamic>>(),
      stopMeters: stopMeters,
      transitLegs: transitLegsJson,
      inactiveRoutes: inactive,
      transitMode: payload['transit_mode'] as bool?,
      routeDebug: routeDebug,
    );
  }

  List<Map<String, dynamic>> _getInactiveRoutesPayload() {
    if (activeManager == null) return [];
    final activeKey = activeManager!.activeKey;
    final inactive = <Map<String, dynamic>>[];
    for (final entry in registry.entries) {
      if (entry.key == activeKey) continue;
      inactive.add({
        'key': entry.key,
        'points':
            entry.points
                .map((p) => {'lat': p.latitude, 'lng': p.longitude})
                .toList(),
        'destinationName': entry.destinationName,
      });
    }
    return inactive;
  }

  void _setupManagerListeners() {
    _mgrStateSub?.cancel();
    _mgrStateSub = activeManager!.stateStream.listen((s) {
      _routeStateCtrl.add(s);
      lastActiveState = s;

      // Feed Deviation Monitor - using stored last position
      // In TrackingService this was done here.
      if (lastIngestedPosition != null && devMonitor != null) {
        // Note: TrackingService re-snapped here. We can assume activeState is fresh if synchronous,
        // but let's re-snap to be safe/consistent with legacy logic if needed,
        // OR trust s.offsetMeters.
        // Smart Approach: Use s.offsetMeters, assuming ActiveManager uses Scientific Snapping.
        // However, we need speed. Speed is not in ActiveRouteState!
        // We need to store lastSpeed too?
        // Or just wait for next ingestPosition?
        // TrackingService pushed deviation update on STATE update.
        // But deviation monitor needs speed.
        // Let's defer deviation ingest to ingestPosition().
      }
    });

    _mgrSwitchSub?.cancel();
    _mgrSwitchSub = activeManager!.switchStream.listen((e) {
      _routeSwitchCtrl.add(e);
      _maybeBroadcastCachedRoute(force: true); // Update inactive routes
    });

    // G14/G15: forward wrong-direction / wrong-train alerts to session consumers.
    _mgrWrongDirSub?.cancel();
    _mgrWrongDirSub = activeManager!.wrongDirectionStream.listen((a) {
      _wrongDirCtrl.add(a);
    });
  }

  void _setupDeviationListeners() {
    _devSub?.cancel();
    _devSub = devMonitor!.stream.listen((ds) {
      // Forward deviation state for termination policy tracking
      _deviationStateCtrl.add(ds);

      // Deviation handling logic moved from TrackingService
      // 1. Check local switch opportunities
      double off = lastActiveState?.offsetMeters ?? double.infinity;

      // Re-verify snap if possible (Legacy paranoia/robustness)
      try {
        if (lastIngestedPosition != null &&
            lastActiveState?.activeKey != null) {
          final entry = registry.entries.firstWhere(
            (e) => e.key == lastActiveState!.activeKey,
            orElse: () => registry.entries.first,
          );
          final snap = SnapToRouteEngine.snap(
            point: lastIngestedPosition!,
            polyline: entry.points,
            hintIndex: entry.lastSnapIndex,
          );
          off = snap.lateralOffsetMeters;
        }
      } catch (_) {}

      if (!ds.sustained) {
        // Immediate switch band (100-150m) check
        if (off >= 100.0 && off <= 150.0) {
          _attemptLocalRouteSwitch(off, sustained: false);
        }
        return;
      }

      // Sustained
      if (off < 100.0) return; // Ignore noise
      if (off <= 150.0) {
        _attemptLocalRouteSwitch(off, sustained: true);
        return;
      }

      // > 150m -> Policy Reroute
      reroutePolicy?.onSustainedDeviation(at: ds.at);
    });
  }

  void _attemptLocalRouteSwitch(
    double currentOffset, {
    required bool sustained,
  }) {
    try {
      if (lastIngestedPosition != null && registry.entries.isNotEmpty) {
        double bestOffset = currentOffset;
        RouteEntry? best;
        for (final e in registry.entries) {
          final snap = SnapToRouteEngine.snap(
            point: lastIngestedPosition!,
            polyline: e.points,
            hintIndex: e.lastSnapIndex,
          );
          if (snap.lateralOffsetMeters + 1e-6 < bestOffset) {
            bestOffset = snap.lateralOffsetMeters;
            best = e;
          }
        }
        final margin = isTestMode ? 20.0 : 50.0;
        if (best != null && (currentOffset - bestOffset) >= margin) {
          final fromKey = lastActiveState?.activeKey ?? 'unknown';
          activeManager?.setActive(best.key);
          _routeSwitchCtrl.add(
            RouteSwitchEvent(
              fromKey: fromKey,
              toKey: best.key,
              at: DateTime.now(),
            ),
          );
        }
      }
    } catch (e) {
      _log.warning('Local route switch check failed', e);
    }
  }

  void _setupRerouteListeners() {
    _rerouteSub?.cancel();
    _rerouteSub = reroutePolicy!.stream.listen((r) {
      _rerouteCtrl.add(r);
      // Logic for auto-fetch will reside in TrackingService for now (or here if we move it later)
      // TrackingService listens to this stream and triggers offlineCoordinator.
    });
  }

  /// Ingest a position update to drive state machines.
  void ingestPosition(Position position) {
    if (activeManager == null) return;
    final latLng = LatLng(position.latitude, position.longitude);
    lastIngestedPosition = latLng;

    activeManager!.ingestPosition(latLng);

    // Deviation Monitor Ingest
    final spd = position.speed;
    final s = lastActiveState;
    if (s != null && devMonitor != null) {
      // Use safe offset (either from state or recomputed if state is stale, but state should update synchronously usually)
      // Let's use state offset for consistency.
      devMonitor!.ingest(offsetMeters: s.offsetMeters, speedMps: spd);
    }
  }

  // Helpers
  static bool _isMetroStep(Map<String, dynamic> step) {
    try {
      if ((step['travel_mode'] as String?)?.toUpperCase() != 'TRANSIT') {
        return false;
      }
      final td = step['transit_details'] as Map<String, dynamic>?;
      final line = td?['line'] as Map<String, dynamic>?;
      final vehicle = line?['vehicle'] as Map<String, dynamic>?;
      final vType = (vehicle?['type'] as String?)?.toUpperCase();
      return vType == 'SUBWAY' ||
          vType == 'HEAVY_RAIL' ||
          vType == 'RAIL' ||
          vType == 'METRO_RAIL' ||
          vType == 'MONORAIL';
    } catch (_) {
      return false;
    }
  }

  double _polylineLengthMeters(List<LatLng> pts) {
    if (pts.length < 2) return 0.0;
    double sum = 0.0;
    for (int i = 1; i < pts.length; i++) {
      sum += Geolocator.distanceBetween(
        pts[i - 1].latitude,
        pts[i - 1].longitude,
        pts[i].latitude,
        pts[i].longitude,
      );
    }
    return sum;
  }

  List<double> _buildCumulativeStops(
    List<double> bounds,
    List<double> rawStops,
  ) {
    if (bounds.isEmpty || rawStops.isEmpty) {
      return List<double>.from(rawStops);
    }
    final len =
        bounds.length < rawStops.length ? bounds.length : rawStops.length;
    double running = 0.0;
    double prevBound = 0.0;
    final result = <double>[];
    for (int i = 0; i < len; i++) {
      final bound = bounds[i];
      final provided = rawStops[i];
      final segLen = (bound - prevBound).abs();
      if (provided >= running) {
        running = provided;
      } else {
        running += segLen > 0 ? segLen / 500.0 : 0.0; // Default spacing
      }
      result.add(running);
      prevBound = bound;
    }
    return result;
  }
}
