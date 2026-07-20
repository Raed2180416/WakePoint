// lib/screens/maptracking.dart

import 'dart:async'; // Streams and timers for location and UI.
import 'dart:math'; // Bounds computation (min/max).
import 'dart:developer' as dev; // Logging.
import 'package:flutter/material.dart'; // UI widgets.
import 'package:google_fonts/google_fonts.dart'; // Title font.
import 'package:google_maps_flutter/google_maps_flutter.dart'; // Google Map, Marker, Polyline, LatLng.
import 'package:geowake2/services/polyline_decoder.dart'; // Decode overview polylines.
import 'package:geowake2/services/monetization/ad_policy.dart';
import 'package:geowake2/widgets/gated_banner_ad.dart';
import 'package:geowake2/services/direction_service.dart'; // Build segmented polylines from directions.
import 'package:geowake2/services/polyline_simplifier.dart'; // Simplify fallback overview.
import 'package:geolocator/geolocator.dart'; // Position stream and distances.
import 'package:geowake2/screens/settingsdrawer.dart'; // Drawer component via package import.
import 'package:geowake2/services/snap_to_route.dart'; // Snapping engine.
import 'package:geowake2/services/trackingservice.dart'; // Streams for switch/state + stopTracking.
import 'package:geowake2/services/active_route_manager.dart'; // Types for events and state.
import 'package:geowake2/services/transfer_utils.dart'; // Transfer/segment boundary helpers.
import 'package:geowake2/widgets/pulsing_dots.dart'; // UI loading dots.
import 'package:geowake2/services/eta_utils.dart'; // ETA calculation by steps.
import 'package:geowake2/services/alarm_player.dart'; // Alarm control.
import 'package:flutter_background_service/flutter_background_service.dart'; // Notify service when stopping alarm.
import 'package:geowake2/services/location_manager.dart'; // For broadcasting device position.
import 'package:geowake2/services/tracking_state_store.dart'; // Snapshot fallback for mode.
import 'package:geowake2/services/notification_service.dart'; // Real alarm path for post-arrival re-alert.
import 'package:geowake2/services/tracking/arrival_hooks.dart'; // Fire-and-forget post-arrival fan-out.
import '../widgets/share/share_journey_action.dart'; // Free "Share ride status" AppBar action.

class MapTrackingScreen extends StatefulWidget {
  // Displays map and live tracking details.
  const MapTrackingScreen({super.key});
  @override
  State<MapTrackingScreen> createState() => _MapTrackingScreenState(); // State factory.
}

class _MapTrackingScreenState extends State<MapTrackingScreen> {
  // Stateful controller for live map tracking.
  final Completer<GoogleMapController> _mapController =
      Completer(); // For camera control.
  bool _isLoading = true; // Show spinner while building polylines.
  double? _destinationLat; // Destination latitude argument.
  double? _destinationLng; // Destination longitude argument.
  String? _destinationName; // Destination name.
  // Boarding origin captured at trip start (initial user fix from nav args).
  // Used ONLY by the post-arrival, consent-gated aggregate surface; never by the
  // alarm/wake spine. _currentUserLocation moves to the destination during the
  // ride, so the origin must be snapshotted here at arg-parse time.
  double? _originLat;
  double? _originLng;
  bool _metroMode = false; // Whether route is metro-inclusive.
  bool _isMetroTimeMode = false; // Metro + time-mode: destination-only toggle.
  Set<Marker> _markers = {}; // Map markers set.
  Set<Polyline> _polylines = {}; // Route polylines to draw.
  String _etaText = "Calculating ETA..."; // UI ETA text.
  String _distanceText = "Calculating distance..."; // UI distance text.
  String? _switchNotice; // Upcoming transfer notice.
  bool _hasValidArgs = false; // Ensures args present.
  bool _finalAlarmActive = false; // Destination alarm UI mode.
  bool _isEndingTracking = false; // Prevents UI flicker during end tracking.

  Map<String, dynamic>? directions; // Raw directions payload.

  // StreamSubscription to update the current location marker. // Foreground position updates.
  StreamSubscription<Position>? _locationSubscription; // Position stream sub.
  LatLng? _currentUserLocation; // Last known user position.
  List<LatLng> _routePoints =
      const []; // Flattened polyline points for snapping.
  int? _lastSnapIndex; // Hint index for snap continuity.
  StreamSubscription<RouteSwitchEvent>?
  _routeSwitchSub; // Listen to route switch events.
  StreamSubscription<ActiveRouteState>?
  _routeStateSub; // Listen to active route state updates.
  StreamSubscription<Position>?
  _simulatedLocationSub; // Listen for simulated positions from TrackingService.
  StreamSubscription<double?>?
  _etaSub; // Listen for background-computed ETA (EtaEngine).
  double? _lastEtaSecondsFromService;
  double _routeLengthMeters = 0.0; // Total route length in meters.
  double?
  _speedEmaMps; // simple smoothed speed estimate // Exponential moving average of speed.
  final List<double> _transferBoundariesMeters =
      []; // Cumulative meters at transfers.
  final List<double> _stepBoundariesMeters =
      []; // Cumulative meters at step ends.
  final List<double> _stepDurationsSeconds = []; // Step durations in seconds.
    List<Map<String, dynamic>> _rawSegments = const []; // Raw route segments.
    List<double> _segmentStartMeters = const []; // Segment start meters.
    List<double> _segmentEndMeters = const []; // Segment end meters.
    double? _lastProgressMeters; // Last progress used to trim polylines.

  // GPS-out / dead-reckoning indicator: when position updates stop arriving
  // (e.g. a tunnel), show a subtle "estimating from motion" state instead of a
  // silently frozen marker. Self-contained: driven by position-update freshness.
  DateTime? _lastPositionAt; // Timestamp of the most recent position update.
  bool _gpsEstimating = false; // True when GPS has gone stale mid-journey.
  Timer? _gpsFreshnessTimer; // Periodically checks position freshness.
  // GPS is considered lost once no position has arrived for this long.
  static const Duration _gpsStaleAfter = Duration(seconds: 12);

  // Post-arrival re-alert (snooze): if the rider dismisses the destination
  // alarm but is still on board, re-fire the real alarm once after a short wait.
  Timer? _snoozeTimer; // Pending one-shot re-alert.
  bool _snoozeUsed = false; // Ensures we only re-alert once (never loop).

  @override
  void initState() {
    super.initState();
    AlarmPlayer.isPlaying.addListener(_onAlarmPlayingChanged);
    _refreshFinalAlarmState();
    // Watch position freshness so we can flip to an "estimating" indicator when
    // GPS drops out (tunnels), and back to normal when fixes resume.
    _gpsFreshnessTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _evaluateGpsFreshness(),
    );
  }

  /// Flip the "estimating from motion" indicator based on how long it has been
  /// since the last position update. Only engages after at least one fix so we
  /// never show it on a cold start.
  void _evaluateGpsFreshness() {
    if (!mounted) return;
    final last = _lastPositionAt;
    final estimating =
        last != null && DateTime.now().difference(last) > _gpsStaleAfter;
    if (estimating == _gpsEstimating) return;
    setState(() {
      _gpsEstimating = estimating;
      _applyEstimatingToMarker(estimating);
    });
  }

  /// Recolor/relabel the current-location marker to signal that its position is
  /// being estimated (orange) rather than freshly measured (default).
  void _applyEstimatingToMarker(bool estimating) {
    final pos = _currentUserLocation;
    if (pos == null) return;
    _markers.removeWhere((m) => m.markerId.value == 'currentLocationMarker');
    _markers.add(
      Marker(
        markerId: const MarkerId('currentLocationMarker'),
        position: pos,
        icon:
            estimating
                ? BitmapDescriptor.defaultMarkerWithHue(
                  BitmapDescriptor.hueOrange,
                )
                : BitmapDescriptor.defaultMarker,
        infoWindow: InfoWindow(
          title: estimating ? 'Estimating position (no GPS)' : 'Your Location',
        ),
      ),
    );
  }

  void _onAlarmPlayingChanged() {
    _refreshFinalAlarmState();
  }

  Future<void> _refreshFinalAlarmState() async {
    if (!mounted || _isEndingTracking) return;
    final isPlaying = AlarmPlayer.isPlaying.value;
    if (!isPlaying) {
      if (_finalAlarmActive) {
        setState(() {
          _finalAlarmActive = false;
        });
      }
      return;
    }

    final allowContinue =
        await TrackingStateStore.pendingAlarmAllowContinue();
    if (!mounted) return;
    final next = isPlaying && allowContinue == false;
    if (next != _finalAlarmActive) {
      setState(() {
        _finalAlarmActive = next;
      });
    }
  }

  /// SNOOZE the destination alarm: silence it now but keep tracking, and arm a
  /// one-shot re-alert in case the rider is still on board and hasn't gotten
  /// off. Deliberately one-time so it can never suppress a needed alarm.
  Future<void> _onSnoozePressed() async {
    // Silence the currently-playing alarm without ending the session.
    await AlarmPlayer.stop();
    try {
      FlutterBackgroundService().invoke('stopAlarm');
    } catch (e) {
      dev.log('Failed to send stopAlarm to service: $e', name: 'MapTracking');
    }

    _snoozeUsed = true;
    _snoozeTimer?.cancel();
    _snoozeTimer = Timer(const Duration(seconds: 60), _maybeReAlert);

    if (!mounted) return;
    setState(() {}); // Hide the SNOOZE button now that it is used.
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          "Snoozed — we'll re-check in a minute in case you're still on board.",
        ),
      ),
    );
  }

  /// Fire the REAL alarm once more if the rider still appears to be travelling
  /// (session active and not manually ended). Over-alerting is safe; never
  /// suppress a needed alarm.
  Future<void> _maybeReAlert() async {
    _snoozeTimer = null;
    if (!mounted || _isEndingTracking) return;

    // Safety: only re-alert while a session is still active (the rider didn't
    // end tracking in the meantime).
    try {
      final active = await TrackingStateStore.isActive();
      if (!active) return;
    } catch (_) {}

    try {
      await NotificationService().showWakeUpAlarm(
        title: 'Still heading past ${_destinationName ?? 'your stop'}',
        body: "You may not have gotten off yet — wake up!",
        allowContinueTracking: false,
        playSound: true,
      );
    } catch (e) {
      dev.log('Post-arrival re-alert failed: $e', name: 'MapTracking');
    }
  }

  @override
  void didChangeDependencies() {
    // Parse arguments and initialize map overlays and streams.
    super.didChangeDependencies(); // Call base.
    final args =
        ModalRoute.of(context)?.settings.arguments
            as Map<String, dynamic>?; // Expect map of arguments.
    dev.log(
      "MapTrackingScreen received args: ${args.toString()}",
      name: "MapTrackingScreen",
    ); // Log args for debugging.
    if (args == null ||
        args['lat'] == null ||
        args['lng'] == null ||
        args['destination'] == null ||
        args['directions'] == null) {
      // Validate required args.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // Show dialog on next frame to avoid build conflicts.
        showDialog(
          context: context,
          builder:
              (ctx) => AlertDialog(
                title: const Text("Error"),
                content: const Text("Destination information missing."),
                actions: [
                  TextButton(
                    onPressed: () {
                      Navigator.of(ctx).pop();
                      Navigator.pop(context);
                    },
                    child: const Text("OK"),
                  ),
                ],
              ),
        );
      });
      return; // Exit early.
    }
    _hasValidArgs = true; // Flag OK.
    _destinationName = args['destination']; // Assign.
    _destinationLat = args['lat']; // Assign.
    _destinationLng = args['lng']; // Assign.
    _metroMode = args['metroMode'] ?? false; // Optional flag.

    // Determine whether we're in the special Metro + Time Mode.
    // In this mode, the settings drawer should show the destination-only toggle
    // (instead of the stop-mode preboarding toggle).
    final modeRaw =
        (args['mode'] ?? args['alarmMode'] ?? args['alarm_mode'])?.toString();
    _isMetroTimeMode = _metroMode && modeRaw == 'time';
    if (_metroMode && modeRaw == null) {
      // Some navigation paths may omit the alarm mode; use the persisted snapshot.
      // This keeps MapTracking consistent with HomeScreen/Splash restore.
      TrackingStateStore.loadSnapshot()
          .then((snapshot) {
            if (!mounted || snapshot == null) return;
            final derived = snapshot.metroMode && snapshot.alarmMode == 'time';
            if (derived != _isMetroTimeMode) {
              setState(() {
                _isMetroTimeMode = derived;
              });
            }
          })
          .catchError((_) {
            // Ignore snapshot load errors; default behavior remains.
          });
    }

    double userLat = args['userLat'] ?? 37.422; // Default lat if missing.
    double userLng = args['userLng'] ?? -122.084; // Default lng if missing.
    _currentUserLocation = LatLng(userLat, userLng); // Seed current location.
    // Snapshot the boarding origin now, before position updates move
    // _currentUserLocation toward the destination. Only used by the opt-in
    // aggregate surface (consent default OFF); absent/default coords simply fail
    // to snap to a catalogue station and are dropped.
    _originLat = args['userLat'];
    _originLng = args['userLng'];
    dev.log(
      "MapTrackingScreen: Destination: $_destinationName, ($_destinationLat, $_destinationLng)",
      name: "MapTrackingScreen",
    ); // Log destination.
    dev.log(
      "MapTrackingScreen: Initial user location: ($userLat, $userLng)",
      name: "MapTrackingScreen",
    ); // Log user.

    _markers = {
      // Initial markers: destination and user.
      Marker(
        markerId: const MarkerId('destinationMarker'),
        position: LatLng(_destinationLat!, _destinationLng!),
        infoWindow: InfoWindow(title: _destinationName!),
      ),
      Marker(
        markerId: const MarkerId('currentLocationMarker'),
        position: _currentUserLocation!,
        infoWindow: const InfoWindow(title: 'Your Location'),
      ),
    };

    _etaText = args['eta']?.toString() ?? _etaText; // Optional precomputed ETA.
    _distanceText =
        args['distance']?.toString() ??
        _distanceText; // Optional precomputed distance.
    directions = args['directions']; // Raw directions for polylines.
    if (directions != null) {
      // If present, build map overlays.
      if (_metroMode) {
        // Metro-specific segmentation (colors, styles per mode).
        final directionService = DirectionService(); // Instantiate.
        // 1. Build raw high-res segments for physics/snapping
        final rawSegments = directionService.buildRawSegments(
          directions!,
          true,
          simplify: false,
        );
        // 2. Build simplified polylines for UI rendering
        final segmentedPolylines =
            directionService.buildSegmentedPolylinesFromRawSegments(
              rawSegments,
            );

        setState(() {
          _polylines = segmentedPolylines.toSet(); // Assign set for Map.
          _storeRawSegments(rawSegments); // Keep for trimming.
          // Flatten raw high-res points for accurate snapping
          _routePoints = rawSegments
              .expand<LatLng>((s) {
                final pts = s['points'] as List;
                return pts
                    .map<LatLng>((p) => LatLng(p['lat'], p['lng']))
                    .toList();
              })
              .toList(growable: false);
          _isLoading = false; // Hide spinner.
        });
        _computeRouteLength(); // Sum length.
        _buildTransferBoundariesFromDirections(); // Compute transfer boundaries.
        _buildStepBoundariesAndDurations(); // Build step boundaries/durations.
        _computeInitialMetrics(userLat, userLng); // Derive ETA/distance.
        _adjustCamera(userLat, userLng); // Fit bounds.
      } else {
        try {
          final directionService = DirectionService(); // Instantiate.
          final rawSegments = directionService.buildRawSegments(
            directions!,
            false,
          );
          final segmentedPolylines =
              directionService.buildSegmentedPolylinesFromRawSegments(
                rawSegments,
              ); // Driving/walking segmentation.
          if (segmentedPolylines.isNotEmpty) {
            // Normal path.
            setState(() {
              _polylines = segmentedPolylines.toSet(); // Draw polylines.
              _storeRawSegments(rawSegments); // Keep for trimming.
              _routePoints = segmentedPolylines
                  .expand((p) => p.points)
                  .toList(growable: false); // Flatten for snapping.
              _isLoading = false; // Done loading.
            });
          } else {
            // Step data missing -> fallback to overview polyline.
            // Fallback to overview polyline if step data is missing
            final route = directions!['routes'][0];
            final String encodedPolyline =
                route['overview_polyline']['points']
                    as String; // Encoded polyline.
            final points = PolylineSimplifier.simplifyPolyline(
              decodePolyline(encodedPolyline),
              10,
            ); // Decode and simplify.
            setState(() {
              _polylines = {
                // Single polyline fallback.
                Polyline(
                  polylineId: const PolylineId('route'),
                  points: points,
                  color: Colors.blue,
                  width: 4,
                ),
              };
              _storeRawSegments([
                {
                  'mode': 'driving',
                  'points':
                      points
                          .map(
                            (p) => {'lat': p.latitude, 'lng': p.longitude},
                          )
                          .toList(),
                },
              ]);
              _routePoints = points; // Flatten.
              _isLoading = false; // Done.
            });
          }
          _computeRouteLength(); // Compute total length.
          _transferBoundariesMeters
              .clear(); // No transfers expected for non-metro; ensure cleared.
          _buildStepBoundariesAndDurations(); // Step boundaries for ETA.
          _computeInitialMetrics(userLat, userLng); // Initial ETA/distance.
          _adjustCamera(userLat, userLng); // Fit camera.
        } catch (e) {
          if (mounted) {
            setState(() {
              _isLoading = false; // Stop spinner.
            });
            dev.log(
              "Error processing directions data: $e",
              name: "MapTrackingScreen",
            ); // Log.
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text("Error processing directions data: $e"),
              ), // User feedback.
            );
          }
        }
      }
    } else {
      // No directions provided.
      setState(() {
        _isLoading = false; // Stop spinner.
      });
      dev.log(
        "No valid routes in directions data",
        name: "MapTrackingScreen",
      ); // Log.
    }

    // Start listening for location updates to update the current location marker.
    _startLocationUpdates(); // Begin foreground updates.

    // Listen for route switches from TrackingService and show a banner.
    _routeSwitchSub ??= TrackingService().routeSwitchStream.listen((evt) {
      // Switch banner.
      if (!mounted) return; // Guard.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Switched route: ${evt.fromKey} → ${evt.toKey}'),
        ),
      );
    });

    // Listen for simulated positions from TrackingService (e.g., from unified dashboard).
    // This ensures the map marker updates even when positions are injected via WebSocket.
    _simulatedLocationSub ??= TrackingService().locationStream.listen((
      position,
    ) {
      if (!mounted) return;
      _handlePositionUpdate(position);
    });

    // Listen for ETA computed by the background EtaEngine (authoritative).
    // This keeps MapTrackingScreen ETA consistent with the unified dashboard.
    _etaSub ??= TrackingService().etaSecondsStream.listen((etaSeconds) {
      if (!mounted) return;
      if (etaSeconds == null || !etaSeconds.isFinite) return;

      _lastEtaSecondsFromService = etaSeconds;

      final double etaSec = etaSeconds.clamp(0.0, double.infinity);
      String etaStr;
      if (etaSec < 90) {
        etaStr = '${etaSec.toStringAsFixed(0)} sec remaining';
      } else if (etaSec < 3600) {
        etaStr = '${(etaSec / 60).toStringAsFixed(0)} min remaining';
      } else {
        etaStr = '${(etaSec / 3600).toStringAsFixed(1)} hr remaining';
      }

      setState(() {
        _etaText = etaStr;
      });
    });

    // Listen for continuous route state to compute ETA and remaining distance.
    _routeStateSub ??= TrackingService().activeRouteStateStream.listen((state) {
      // Update summary cards.
      if (!mounted) return; // Guard.
      // Remaining distance from manager
      final remainingM =
          state.remainingMeters; // Remaining meters provided by manager.
      // Derive ETA using step durations when available; otherwise use a
      // conservative fallback speed (avoid overly optimistic ~43 km/h defaults).
      final serviceEta = _lastEtaSecondsFromService;
      double etaSec =
          (serviceEta != null && serviceEta.isFinite)
              ? serviceEta
              : (EtaUtils.etaRemainingSeconds(
                    progressMeters: state.progressMeters,
                    stepBoundariesMeters: _stepBoundariesMeters,
                    stepDurationsSeconds: _stepDurationsSeconds,
                  ) ??
                  (remainingM /
                      (((_speedEmaMps != null &&
                                  _speedEmaMps!.isFinite &&
                                  _speedEmaMps! > 0.5)
                              ? _speedEmaMps!
                              : 2.8)
                          .clamp(0.5, 20.0))));
      // Format
      String etaStr; // Human readable ETA.
      if (etaSec < 90) {
        etaStr = '${etaSec.toStringAsFixed(0)} sec remaining';
      } else if (etaSec < 3600) {
        etaStr = '${(etaSec / 60).toStringAsFixed(0)} min remaining';
      } else {
        etaStr = '${(etaSec / 3600).toStringAsFixed(1)} hr remaining';
      }
      String distStr =
          remainingM >= 1000
              ? '${(remainingM / 1000).toStringAsFixed(2)} km to destination'
              : '${remainingM.toStringAsFixed(0)} m to destination';

      String? switchMsg; // Upcoming transfer display.
      if (state.pendingSwitchToKey != null &&
          state.pendingSwitchInSeconds != null) {
        final secs = state.pendingSwitchInSeconds!; // Seconds until switch.
        final when =
            secs < 60
                ? '${secs.toStringAsFixed(0)} sec'
                : '${(secs / 60).toStringAsFixed(0)} min'; // Humanize.
        switchMsg = "You'll have to switch routes in $when"; // Compose.

        // Debug: this countdown is about ACTIVE ROUTE switching (route manager),
        // not necessarily a transit transfer switchpoint.
        print(
          'MAP_ROUTE_SWITCH_DEBUG: pendingTo=${state.pendingSwitchToKey}, '
          'pendingSecs=${secs.toStringAsFixed(1)}, '
          'progress=${state.progressMeters.toStringAsFixed(0)}',
        );
      }

      setState(() {
        _etaText = etaStr; // Apply ETA.
        _distanceText = distStr; // Apply distance.
        _switchNotice = switchMsg; // Apply notice.
      });
    });
  }

  /// Shared handler for both real GPS and simulated position updates.
  void _handlePositionUpdate(Position position) {
    _currentUserLocation = LatLng(position.latitude, position.longitude);
    // A fresh fix arrived: reset the freshness clock and clear any estimating
    // state (marker recolor happens with the marker rebuild below).
    _lastPositionAt = DateTime.now();
    _gpsEstimating = false;
    dev.log(
      "MapTrackingScreen: Position update: (${position.latitude.toStringAsFixed(5)}, ${position.longitude.toStringAsFixed(5)})",
      name: "MapTrackingScreen",
    );

    // Smooth speed estimate
    final rawSpeed = position.speed;
    if (rawSpeed.isFinite && rawSpeed >= 0) {
      final v =
          rawSpeed < 0.5 && _speedEmaMps != null ? _speedEmaMps! : rawSpeed;
      _speedEmaMps = _speedEmaMps == null ? v : (_speedEmaMps! * 0.8 + v * 0.2);
    }

    // Prefer snapped position onto the route if available
    LatLng markerPos = _currentUserLocation!;
    if (_routePoints.length >= 2) {
      final snap = SnapToRouteEngine.snap(
        point: _currentUserLocation!,
        polyline: _routePoints,
        hintIndex: _lastSnapIndex,
        searchWindow: 30,
      );
      _lastSnapIndex = snap.segmentIndex;
      markerPos = snap.snappedPoint;

      // Compute remaining distance and ETA locally
      final progress = snap.progressMeters;
      final remaining = (_routeLengthMeters - progress).clamp(
        0.0,
        double.infinity,
      );

      // ETA to destination: combine step-duration ETA with speed ETA.
      const double speedSafetyFactor = 1.20;
      const double maxStepInflationVsSpeed = 1.50;

      final stepEtaToDestSec = EtaUtils.etaRemainingSeconds(
        progressMeters: progress,
        stepBoundariesMeters: _stepBoundariesMeters,
        stepDurationsSeconds: _stepDurationsSeconds,
      );

      final spdToDest =
          (_speedEmaMps != null && _speedEmaMps! > 0.5) ? _speedEmaMps! : 2.8;
      final speedEtaToDestSec = remaining / spdToDest;

      final double etaSec;
      if (stepEtaToDestSec != null) {
        final speedBuffered = speedEtaToDestSec * speedSafetyFactor;
        final stepCap = speedBuffered * maxStepInflationVsSpeed;
        etaSec =
            (stepEtaToDestSec <= speedBuffered)
                ? speedBuffered
                : (stepEtaToDestSec <= stepCap ? stepEtaToDestSec : stepCap);
      } else {
        etaSec = speedEtaToDestSec * speedSafetyFactor;
      }

      final etaStr =
          etaSec < 90
              ? '${etaSec.toStringAsFixed(0)} sec remaining'
              : etaSec < 3600
              ? '${(etaSec / 60).toStringAsFixed(0)} min remaining'
              : '${(etaSec / 3600).toStringAsFixed(1)} hr remaining';
      final distStr =
          remaining >= 1000
              ? '${(remaining / 1000).toStringAsFixed(2)} km to destination'
              : '${remaining.toStringAsFixed(0)} m to destination';

      String? switchMsg;
      if (_transferBoundariesMeters.isNotEmpty) {
        final next = _transferBoundariesMeters.firstWhere(
          (b) => b > progress,
          orElse: () => -1,
        );
        if (next > 0) {
          final toSwitchM = next - progress;
          final spd =
              (_speedEmaMps != null && _speedEmaMps! > 0.5)
                  ? _speedEmaMps!
                  : 2.8;
          final stepEtaSec = EtaUtils.etaToTargetSeconds(
            progressMeters: progress,
            targetMeters: next,
            stepBoundariesMeters: _stepBoundariesMeters,
            stepDurationsSeconds: _stepDurationsSeconds,
          );
          final speedEtaSec = toSwitchM / spd;
          final double tSec;
          if (stepEtaSec != null) {
            final speedBuffered = speedEtaSec * speedSafetyFactor;
            final stepCap = speedBuffered * maxStepInflationVsSpeed;
            tSec =
                (stepEtaSec <= speedBuffered)
                    ? speedBuffered
                    : (stepEtaSec <= stepCap ? stepEtaSec : stepCap);
          } else {
            tSec = speedEtaSec * speedSafetyFactor;
          }

          print(
            'MAP_SWITCH_ETA_DEBUG: progress=${progress.toStringAsFixed(0)}, '
            'nextBoundary=${next.toStringAsFixed(0)}, '
            'toSwitchM=${toSwitchM.toStringAsFixed(0)}, '
            'stepEtaSec=${stepEtaSec?.toStringAsFixed(1) ?? "null"}, '
            'speedEtaSec=${speedEtaSec.toStringAsFixed(1)}, '
            'chosenSec=${tSec.toStringAsFixed(1)}, '
            'speedEma=${_speedEmaMps?.toStringAsFixed(2) ?? "null"}, '
            'boundaries=${_transferBoundariesMeters.length}',
          );
          final when =
              tSec < 60
                  ? '${tSec.toStringAsFixed(0)} sec'
                  : '${(tSec / 60).toStringAsFixed(0)} min';
          switchMsg = "You'll have to switch routes in $when";
        }
      }

      Set<Polyline>? remainingPolylines;
      if (_rawSegments.isNotEmpty) {
        if (_lastProgressMeters == null ||
            (progress - _lastProgressMeters!).abs() >= 5.0) {
          remainingPolylines = _buildRemainingPolylines(progress, markerPos);
          _lastProgressMeters = progress;
        }
      }

      if (mounted) {
        setState(() {
          _etaText = etaStr;
          _distanceText = distStr;
          _switchNotice = switchMsg;
          if (remainingPolylines != null) {
            _polylines = remainingPolylines;
          }
        });
      }
    }

    // Update the marker for current (snapped) location.
    if (mounted) {
      setState(() {
        _markers.removeWhere(
          (m) => m.markerId.value == 'currentLocationMarker',
        );
        _markers.add(
          Marker(
            markerId: const MarkerId('currentLocationMarker'),
            position: markerPos,
            infoWindow: const InfoWindow(title: 'Your Location'),
          ),
        );
      });
    }
  }

  Future<void> _startLocationUpdates() async {
    // Foreground GPS updates and snapping.
    // Use high accuracy updates in the foreground.
    LocationSettings settings = const LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 5, // Update when moved 5 meters.
    );
    _locationSubscription = Geolocator.getPositionStream(
      locationSettings: settings,
    ).listen((position) {
      // Handle the position update (shared with simulated positions)
      _handlePositionUpdate(position);

      // Broadcast device position to dashboard for real-time sync
      try {
        LocationManager().broadcastPosition(
          lat: position.latitude,
          lng: position.longitude,
          heading: position.heading,
          speed: position.speed,
        );
      } catch (_) {}
    });
  }

  void _computeInitialMetrics(double userLat, double userLng) {
    // First draw ETA/distance after building route.
    if (_routePoints.length < 2) return; // Require polyline.
    final p = LatLng(userLat, userLng); // Current position.
    final snap = SnapToRouteEngine.snap(
      point: p,
      polyline: _routePoints,
      hintIndex: null,
      searchWindow: 30,
    ); // Snap to route.
    final progress = snap.progressMeters; // Meters progressed.
    final remaining = (_routeLengthMeters - progress).clamp(
      0.0,
      double.infinity,
    ); // Remaining meters.
    double? etaSec = EtaUtils.etaRemainingSeconds(
      progressMeters: progress,
      stepBoundariesMeters: _stepBoundariesMeters,
      stepDurationsSeconds: _stepDurationsSeconds,
    );
    if (etaSec == null) {
      final spd = 12.0; // Fallback speed.
      etaSec = remaining / spd; // Simple ETA.
    }
    final etaStr =
        etaSec < 90
            ? '${etaSec.toStringAsFixed(0)} sec remaining'
            : etaSec < 3600
            ? '${(etaSec / 60).toStringAsFixed(0)} min remaining'
            : '${(etaSec / 3600).toStringAsFixed(1)} hr remaining';
    final distStr =
        remaining >= 1000
            ? '${(remaining / 1000).toStringAsFixed(2)} km to destination'
            : '${remaining.toStringAsFixed(0)} m to destination';
    String? switchMsg; // Next transfer message.
    if (_transferBoundariesMeters.isNotEmpty) {
      final next = _transferBoundariesMeters.firstWhere(
        (b) => b > progress,
        orElse: () => -1,
      ); // Find next.
      if (next > 0) {
        final toSwitchM = next - progress; // Meters to transfer.
        final spd = 12.0; // Fallback speed for initial estimation.
        final tSec =
            EtaUtils.etaToTargetSeconds(
              progressMeters: progress,
              targetMeters: next,
              stepBoundariesMeters: _stepBoundariesMeters,
              stepDurationsSeconds: _stepDurationsSeconds,
            ) ??
            (toSwitchM / spd); // Seconds.
        final when =
            tSec < 60
                ? '${tSec.toStringAsFixed(0)} sec'
                : '${(tSec / 60).toStringAsFixed(0)} min'; // Humanize.
        switchMsg = "You'll have to switch routes in $when"; // Compose.
      }
    }
    if (mounted) {
      setState(() {
        _etaText = etaStr; // Apply.
        _distanceText = distStr; // Apply.
        _switchNotice = switchMsg; // Apply.
        // metrics ready
      });
    }
  }

  void _computeRouteLength() {
    // Sum segments of polyline in meters.
    double sum = 0.0; // Accumulator.
    for (var i = 1; i < _routePoints.length; i++) {
      sum += Geolocator.distanceBetween(
        _routePoints[i - 1].latitude,
        _routePoints[i - 1].longitude,
        _routePoints[i].latitude,
        _routePoints[i].longitude,
      );
    }
    _routeLengthMeters = sum; // Store total.
  }

  void _storeRawSegments(List<Map<String, dynamic>> rawSegments) {
    _rawSegments = rawSegments;
    _segmentStartMeters = [];
    _segmentEndMeters = [];
    double cum = 0.0;
    for (final seg in rawSegments) {
      final pts = _segmentPointsFromRaw(seg);
      final len = _segmentLengthMeters(pts);
      _segmentStartMeters.add(cum);
      cum += len;
      _segmentEndMeters.add(cum);
    }
  }

  List<LatLng> _segmentPointsFromRaw(Map<String, dynamic> seg) {
    final pointsData = (seg['points'] as List?) ?? const [];
    return pointsData
        .map(
          (p) => LatLng(
            (p['lat'] as num).toDouble(),
            (p['lng'] as num).toDouble(),
          ),
        )
        .toList(growable: false);
  }

  double _segmentLengthMeters(List<LatLng> pts) {
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

  List<LatLng> _trimPolylineFromMeters(
    List<LatLng> pts,
    double offsetMeters,
  ) {
    if (pts.length < 2 || offsetMeters <= 0) return pts;
    double traveled = 0.0;
    for (int i = 1; i < pts.length; i++) {
      final a = pts[i - 1];
      final b = pts[i];
      final seg = Geolocator.distanceBetween(
        a.latitude,
        a.longitude,
        b.latitude,
        b.longitude,
      );
      if (traveled + seg >= offsetMeters) {
        final t = seg == 0 ? 0.0 : (offsetMeters - traveled) / seg;
        final lat = a.latitude + (b.latitude - a.latitude) * t;
        final lng = a.longitude + (b.longitude - a.longitude) * t;
        final trimmed = <LatLng>[LatLng(lat, lng)];
        trimmed.addAll(pts.sublist(i));
        return trimmed;
      }
      traveled += seg;
    }
    return const [];
  }

  Set<Polyline>? _buildRemainingPolylines(
    double progressMeters,
    LatLng snappedPoint,
  ) {
    if (_rawSegments.isEmpty) return null;
    if (_segmentStartMeters.isEmpty || _segmentEndMeters.isEmpty) return null;
    final remaining = <Map<String, dynamic>>[];
    for (int i = 0; i < _rawSegments.length; i++) {
      final start = _segmentStartMeters[i];
      final end = _segmentEndMeters[i];
      if (progressMeters >= end) {
        continue; // Segment fully behind.
      }
      final seg = _rawSegments[i];
      final pts = _segmentPointsFromRaw(seg);
      if (progressMeters <= start) {
        remaining.add(seg);
        continue;
      }
      final offset = progressMeters - start;
      final trimmed = _trimPolylineFromMeters(pts, offset);
      if (trimmed.isEmpty) continue;
      trimmed[0] = snappedPoint;
      remaining.add({
        'mode': seg['mode'],
        'points':
            trimmed
                .map((p) => {'lat': p.latitude, 'lng': p.longitude})
                .toList(),
        'transit_line': seg['transit_line'],
        'vehicle_type': seg['vehicle_type'],
      });
    }
    if (remaining.isEmpty) return {};
    final polylines = DirectionService()
        .buildSegmentedPolylinesFromRawSegments(remaining);
    return polylines.toSet();
  }

  void _buildTransferBoundariesFromDirections() {
    // Populate transfer boundaries for metro notifications.
    _transferBoundariesMeters
      ..clear()
      ..addAll(
        TransferUtils.buildTransferBoundariesMeters(
          directions!,
          metroMode: _metroMode,
        ),
      ); // Compute from directions.
  }

  void _buildStepBoundariesAndDurations() {
    // Prepare step cumulative meters and durations for ETA interpolation.
    _stepBoundariesMeters.clear(); // Reset.
    _stepDurationsSeconds.clear(); // Reset.
    if (directions == null) return; // Require directions.
    try {
      final routes =
          (directions!['routes'] as List?) ?? const []; // Safe routes.
      if (routes.isEmpty) return; // No routes.
      final route = routes.first as Map<String, dynamic>; // Use first route.
      final legs = (route['legs'] as List?) ?? const []; // Legs list.
      double cum = 0.0; // Cumulative meters.
      for (final leg in legs) {
        final steps = (leg['steps'] as List?) ?? const []; // Steps list.
        for (final step in steps) {
          final m =
              ((step['distance'] as Map<String, dynamic>?)?['value'])
                  as num?; // Step meters.
          final s =
              ((step['duration'] as Map<String, dynamic>?)?['value'])
                  as num?; // Step seconds.
          if (m != null && s != null) {
            cum += m.toDouble(); // Increment cumulative.
            _stepBoundariesMeters.add(cum); // Record boundary.
            _stepDurationsSeconds.add(s.toDouble()); // Record duration.
          }
        }
      }
    } catch (_) {} // Ignore parse errors; will fallback ETA.
  }

  Future<void> _adjustCamera(double userLat, double userLng) async {
    // Fit camera to user and destination.
    final GoogleMapController controller =
        await _mapController.future; // Await controller.
    if (_destinationLat == null || _destinationLng == null) {
      return; // Require destination.
    }
    final bounds = LatLngBounds(
      southwest: LatLng(
        min(userLat, _destinationLat!),
        min(userLng, _destinationLng!),
      ), // SW corner.
      northeast: LatLng(
        max(userLat, _destinationLat!),
        max(userLng, _destinationLng!),
      ), // NE corner.
    );
    controller.animateCamera(
      CameraUpdate.newLatLngBounds(bounds, 50),
    ); // Apply with padding.
  }

  @override
  void dispose() {
    // Clean up streams and controllers.
    AlarmPlayer.isPlaying.removeListener(_onAlarmPlayingChanged);
    _locationSubscription?.cancel(); // Stop GPS stream.
    _routeSwitchSub?.cancel(); // Stop switch stream.
    _routeStateSub?.cancel(); // Stop state stream.
    _simulatedLocationSub?.cancel(); // Stop simulated position stream.
    _etaSub?.cancel(); // Stop ETA stream.
    _gpsFreshnessTimer?.cancel(); // Stop GPS-freshness watcher.
    _snoozeTimer?.cancel(); // Stop pending re-alert.
    super.dispose(); // Parent cleanup.
  }

  @override
  Widget build(BuildContext context) {
    // Compose the map tracking UI.
    if (!_hasValidArgs) {
      // If args missing, show simple error.
      return Scaffold(
        appBar: AppBar(title: const Text("Map Tracking")),
        body: const Center(child: Text("Invalid or missing destination data.")),
      );
    }
    final cs = Theme.of(context).colorScheme;
    final endTrackingStyle = ElevatedButton.styleFrom(
      backgroundColor: cs.errorContainer,
      foregroundColor: cs.onErrorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
    );
    return PopScope(
      // Intercept back button.
      canPop: false, // Prevent pop.
      onPopInvokedWithResult: (bool didPop, dynamic result) async {
        // Back handler.
        if (!didPop) {
          // Handle the back button press here if needed
          // For now, we'll just prevent the pop since canPop is false
        }
      },
      child: Scaffold(
        drawer: SettingsDrawer(
          metroModeEnabled: _metroMode,
          isMetroTimeMode: _isMetroTimeMode,
        ), // Drawer.
        appBar: AppBar(
          title: Row(
            children: [
              Text(
                _metroMode
                    ? 'Metro Tracking'
                    : 'Map Tracking', // Title toggles with mode.
                style: GoogleFonts.pacifico(
                  textStyle: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 26,
                  ),
                ),
              ),
              if (_metroMode) ...[
                const SizedBox(width: 8),
                const Icon(
                  Icons.train,
                  semanticLabel: 'Metro mode',
                ), // Mode icon.
              ],
            ],
          ),
          // FREE "Share ride status" — the viral growth loop. No entitlement
          // check; opens the OS share sheet (WhatsApp/SMS/anything). Read-only,
          // never touches the arm → track → alarm spine.
          actions: [
            ShareJourneyAction(destLabel: _destinationName),
          ],
        ),
        // Above-ground tracking banner (free users only; collapses to nothing
        // for Pro / no-fill). AdPolicy forbids ads on the alarm/wake surfaces,
        // and the full-screen wake alarm supersedes this small banner anyway.
        bottomNavigationBar: const SafeArea(
          child: GatedBannerAd(placement: AdPlacement.mapTracking),
        ),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: Stack(
                  children: [
                    GoogleMap(
                      initialCameraPosition: CameraPosition(
                        target: LatLng(
                          _destinationLat!,
                          _destinationLng!,
                        ), // Start view at destination.
                        zoom: 14,
                      ),
                      markers: _markers, // Markers.
                      polylines: _polylines, // Polylines.
                      onMapCreated: (controller) {
                        if (!_mapController.isCompleted) {
                          _mapController.complete(controller); // Complete once.
                        }
                      },
                    ),
                    // Route legend overlay (compact, avoids overflow)
                    Positioned(
                      top: 12,
                      left: 12,
                      right: 12,
                      child: Material(
                        color: Colors.black.withOpacity(0.5), // Translucent bg.
                        borderRadius: BorderRadius.circular(8),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              return Wrap(
                                spacing: 12,
                                runSpacing: 6,
                                alignment: WrapAlignment.start,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  _LegendItem(
                                    color: Colors.blue,
                                    dashed: false,
                                    label: 'Driving',
                                  ),
                                  _LegendItem(
                                    color: Colors.blue,
                                    dashed: true,
                                    label: 'Walking',
                                  ),
                                  _LegendItem(
                                    color: Colors.green,
                                    dashed: false,
                                    label: 'Metro Line A',
                                  ),
                                  _LegendItem(
                                    color: Colors.purple,
                                    dashed: false,
                                    label: 'Metro Line B',
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                    if (_isLoading)
                      const Center(
                        child: CircularProgressIndicator(),
                      ), // Spinner overlay.
                    // GPS-out reassurance banner (tunnels / dead-reckoning).
                    if (_gpsEstimating)
                      Positioned(
                        left: 12,
                        right: 12,
                        bottom: 12,
                        child: Material(
                          color: Colors.deepOrange.withOpacity(0.92),
                          borderRadius: BorderRadius.circular(8),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.sensors,
                                  color: Colors.white,
                                  size: 20,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'No GPS (tunnel) — estimating position from motion. '
                                    'Still counting down to ${_destinationName ?? 'your stop'}.',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    // Stop alarm button moved to bottom of screen
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          _etaText,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        if (!_etaText.contains('remaining')) ...[
                          const SizedBox(width: 8),
                          const PulsingDots(
                            color: Colors.grey,
                          ), // Loading indicator near ETA.
                        ],
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          _distanceText,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        if (!_distanceText.contains('to destination')) ...[
                          const SizedBox(width: 8),
                          const PulsingDots(
                            color: Colors.grey,
                          ), // Loading indicator near distance.
                        ],
                      ],
                    ),
                    if (_switchNotice != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        _switchNotice!,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: Colors.orange,
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    if (_finalAlarmActive)
                      Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 440),
                          child: Column(
                            children: [
                              // Clear "you've arrived" confirmation state.
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.location_on,
                                    color: cs.primary,
                                    size: 28,
                                  ),
                                  const SizedBox(width: 8),
                                  Flexible(
                                    child: Text(
                                      "You've reached ${_destinationName ?? 'your destination'}",
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              const Text(
                                'Time to get off.',
                                style: TextStyle(fontSize: 14),
                              ),
                              const SizedBox(height: 16),
                              Row(
                                children: [
                                  // SNOOZE: dismiss the alarm sound but keep
                                  // tracking, and re-fire once shortly in case
                                  // the rider is still on board. One-shot only.
                                  if (!_snoozeUsed) ...[
                                    Expanded(
                                      child: Semantics(
                                        label: 'Snooze alarm',
                                        identifier: 'snooze_button',
                                        child: ElevatedButton.icon(
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: cs.secondaryContainer,
                                          foregroundColor:
                                              cs.onSecondaryContainer,
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 16,
                                            vertical: 16,
                                          ),
                                          textStyle: const TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        onPressed: _onSnoozePressed,
                                        icon: const Icon(Icons.snooze, size: 24),
                                        label: const Text('SNOOZE'),
                                      ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                  ],
                                  Expanded(
                                    child: Semantics(
                                      label: 'End tracking',
                                      identifier: 'end_tracking_button_arrived',
                                      child: ElevatedButton.icon(
                                      style: endTrackingStyle,
                                      onPressed: () async {
                                        // Prevent UI flicker during shutdown
                                        setState(() {
                                          _isEndingTracking = true;
                                        });
                                        _snoozeTimer?.cancel();

                                        // Stop alarm sounds and vibration
                                        await AlarmPlayer.stop();

                                        // End tracking completely - clears snapshot, stops service,
                                        // cancels notifications, and resets all tracking state.
                                        // Pass navigateHome: false since we handle navigation here.
                                        await TrackingService()
                                            .completeEndTracking(
                                              navigateHome: false,
                                            );

                                        // Post-arrival fan-out (trip stats, opt-in aggregate,
                                        // Guardian "arrived", ad-cap). Synchronous, fire-and-forget,
                                        // non-blocking — runs only AFTER the alarm fired + teardown,
                                        // so it can never delay/reorder the never-late wake.
                                        // Coordinates feed the consent-gated aggregate surface
                                        // (DataAssetPipeline self-gates on consent, default OFF, as
                                        // its first statement); a missing origin simply skips it.
                                        ArrivalHooks.fireArrived(
                                          destStation: _destinationName,
                                          destLat: _destinationLat,
                                          destLng: _destinationLng,
                                          originLat: _originLat,
                                          originLng: _originLng,
                                          mode: _metroMode ? 'metro' : 'transit',
                                        );

                                        // Show the post-arrival screen (free share + last-mile +
                                        // optional rewarded), which returns the rider home on Done.
                                        Navigator.pushReplacementNamed(
                                          context,
                                          '/postArrival',
                                        );
                                      },
                                      icon: const Icon(
                                        Icons.stop_circle_outlined,
                                        size: 24,
                                      ),
                                      label: const Text('END TRACKING'),
                                    ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      )
                    else
                      Row(
                        children: [
                          // Stop Alarm Button - only visible when alarm is playing
                          Expanded(
                            child: ValueListenableBuilder<bool>(
                              valueListenable:
                                  AlarmPlayer.isPlaying, // Listen to alarm state.
                              builder: (context, playing, child) {
                                final cs =
                                    Theme.of(
                                      context,
                                    ).colorScheme; // Theme colors.
                                return Semantics(
                                  label: 'Stop alarm',
                                  identifier: 'stop_alarm_button',
                                  child: ElevatedButton.icon(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: cs.secondaryContainer,
                                    foregroundColor: cs.onSecondaryContainer,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 16,
                                    ),
                                    textStyle: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                    ),
                                    disabledBackgroundColor:
                                        Colors.grey.shade300,
                                    disabledForegroundColor:
                                        Colors.grey.shade600,
                                  ),
                                  onPressed:
                                      playing
                                          ? () async {
                                            await AlarmPlayer
                                                .stop(); // Stop sound.
                                            try {
                                              // Also notify the background service
                                              final service =
                                                  FlutterBackgroundService();
                                              service.invoke(
                                                'stopAlarm',
                                              ); // Ask service to stop vibration etc.
                                            } catch (e) {
                                              dev.log(
                                                'Failed to send stopAlarm to service: $e',
                                                name: 'MapTracking',
                                              );
                                            }
                                          }
                                          : null, // Button disabled when alarm not playing
                                  icon: const Icon(
                                    Icons.notifications_off,
                                    size: 24,
                                  ),
                                  label: const Text('STOP ALARM'),
                                ),
                                );
                              },
                            ),
                          ),
                          const SizedBox(width: 8), // Spacing between buttons
                          // End Tracking Button
                          Expanded(
                            child: Semantics(
                              label: 'End tracking',
                              identifier: 'end_tracking_button',
                              child: ElevatedButton.icon(
                              style: endTrackingStyle,
                              onPressed: () async {
                                // Prevent UI flicker during shutdown
                                setState(() {
                                  _isEndingTracking = true;
                                });

                                // Stop alarm sounds and vibration
                                await AlarmPlayer.stop();

                                // End tracking completely - clears snapshot, stops service,
                                // cancels notifications, and resets all tracking state.
                                // Pass navigateHome: false since we handle navigation here.
                                await TrackingService().completeEndTracking(
                                  navigateHome: false,
                                );

                                // Navigate back to home screen
                                Navigator.pushReplacementNamed(context, '/');
                              },
                              icon: const Icon(
                                Icons.stop_circle_outlined,
                                size: 24,
                              ),
                              label: const Text('END TRACKING'),
                            ),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LegendItem extends StatelessWidget {
  // Small legend chip for route types.
  final Color color; // Line color.
  final bool dashed; // Dashed or solid.
  final String label; // Text label.
  const _LegendItem({
    required this.color,
    required this.dashed,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    // Render chip.
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        CustomPaint(
          painter: _LineSamplePainter(
            color: color,
            dashed: dashed,
          ), // Draw line sample.
          size: const Size(28, 6), // Sample size.
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
          ), // White small text.
        ),
      ],
    );
  }
}

class _LineSamplePainter extends CustomPainter {
  // Paints a solid or dashed line sample.
  final Color color; // Paint color.
  final bool dashed; // Whether to draw dashes.
  _LineSamplePainter({required this.color, required this.dashed});

  @override
  void paint(Canvas canvas, Size size) {
    // Draw on canvas.
    final paint =
        Paint()
          ..color = color
          ..strokeWidth = 4
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round; // Rounded ends.
    final y = size.height / 2; // Center y.
    if (!dashed) {
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        paint,
      ); // Single solid line.
    } else {
      const double dashWidth = 8.0; // Dash length.
      const double dashSpace = 6.0; // Space length.
      double x = 0.0; // Cursor.
      while (x < size.width) {
        // Repeat dashes.
        final double x2 =
            (x + dashWidth) > size.width
                ? size.width
                : (x + dashWidth); // Clip last dash.
        canvas.drawLine(Offset(x, y), Offset(x2, y), paint); // Draw dash.
        x += dashWidth + dashSpace; // Advance.
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false; // No repaint needed.
}
