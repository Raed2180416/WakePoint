// docs/annotated/screens/maptracking.annotated.dart
// Purpose: Line-by-line annotated copy of `lib/screens/maptracking.dart`.
// Scope: Receives route args, draws segmented polylines, snaps user to route, derives ETA/distance, handles alarm stop/end tracking.

import 'dart:async'; // Streams and timers for location and UI.
import 'dart:math'; // Bounds computation (min/max).
import 'dart:developer' as dev; // Logging.
import 'package:flutter/material.dart'; // UI widgets.
import 'package:google_fonts/google_fonts.dart'; // Title font.
import 'package:google_maps_flutter/google_maps_flutter.dart'; // Google Map, Marker, Polyline, LatLng.
import 'package:geowake2/services/polyline_decoder.dart'; // Decode overview polylines.
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
import 'package:geowake2/services/notification_service.dart'; // Progress notification control.
import 'package:flutter_background_service/flutter_background_service.dart'; // Notify service when stopping alarm.

class MapTrackingScreen extends StatefulWidget { // Displays map and live tracking details.
  MapTrackingScreen({Key? key}) : super(key: key);
  @override
  State<MapTrackingScreen> createState() => _MapTrackingScreenState(); // State factory.
}

class _MapTrackingScreenState extends State<MapTrackingScreen> { // Stateful controller for live map tracking.
  final Completer<GoogleMapController> _mapController = Completer(); // For camera control.
  bool _isLoading = true; // Show spinner while building polylines.
  double? _destinationLat; // Destination latitude argument.
  double? _destinationLng; // Destination longitude argument.
  String? _destinationName; // Destination name.
  bool _metroMode = false; // Whether route is metro-inclusive.
  Set<Marker> _markers = {}; // Map markers set.
  Set<Polyline> _polylines = {}; // Route polylines to draw.
  String _etaText = "Calculating ETA..."; // UI ETA text.
  String _distanceText = "Calculating distance..."; // UI distance text.
  String? _switchNotice; // Upcoming transfer notice.
  bool _hasValidArgs = false; // Ensures args present.

  Map<String, dynamic>? directions; // Raw directions payload.

  // StreamSubscription to update the current location marker. // Foreground position updates.
  StreamSubscription<Position>? _locationSubscription; // Position stream sub.
  LatLng? _currentUserLocation; // Last known user position.
  List<LatLng> _routePoints = const []; // Flattened polyline points for snapping.
  int? _lastSnapIndex; // Hint index for snap continuity.
  StreamSubscription<RouteSwitchEvent>? _routeSwitchSub; // Listen to route switch events.
  StreamSubscription<ActiveRouteState>? _routeStateSub; // Listen to active route state updates.
  double _routeLengthMeters = 0.0; // Total route length in meters.
  double? _speedEmaMps; // simple smoothed speed estimate // Exponential moving average of speed.
  final List<double> _transferBoundariesMeters = []; // Cumulative meters at transfers.
  final List<double> _stepBoundariesMeters = []; // Cumulative meters at step ends.
  final List<double> _stepDurationsSeconds = []; // Step durations in seconds.

  @override
  void didChangeDependencies() { // Parse arguments and initialize map overlays and streams.
    super.didChangeDependencies(); // Call base.
    final args =
        ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?; // Expect map of arguments.
    dev.log("MapTrackingScreen received args: ${args.toString()}",
        name: "MapTrackingScreen"); // Log args for debugging.
    if (args == null ||
        args['lat'] == null ||
        args['lng'] == null ||
        args['destination'] == null ||
        args['directions'] == null) { // Validate required args.
      WidgetsBinding.instance.addPostFrameCallback((_) { // Show dialog on next frame to avoid build conflicts.
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
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
    double userLat = args['userLat'] ?? 37.422; // Default lat if missing.
    double userLng = args['userLng'] ?? -122.084; // Default lng if missing.
    _currentUserLocation = LatLng(userLat, userLng); // Seed current location.
    dev.log("MapTrackingScreen: Destination: $_destinationName, ($_destinationLat, $_destinationLng)",
        name: "MapTrackingScreen"); // Log destination.
    dev.log("MapTrackingScreen: Initial user location: ($userLat, $userLng)",
        name: "MapTrackingScreen"); // Log user.

    _markers = { // Initial markers: destination and user.
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
    _distanceText = args['distance']?.toString() ?? _distanceText; // Optional precomputed distance.
    directions = args['directions']; // Raw directions for polylines.
    if (directions != null) { // If present, build map overlays.
      if (_metroMode) { // Metro-specific segmentation (colors, styles per mode).
        final directionService = DirectionService(); // Instantiate.
        final segmentedPolylines =
            directionService.buildSegmentedPolylines(directions!, true); // Build metro polylines.
        setState(() {
          _polylines = segmentedPolylines.toSet(); // Assign set for Map.
          // For metro, merge all polylines to a single list for snapping (optional)
          _routePoints = segmentedPolylines.expand((p) => p.points).toList(growable: false); // Flatten points.
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
          final segmentedPolylines =
              directionService.buildSegmentedPolylines(directions!, false); // Driving/walking segmentation.
          if (segmentedPolylines.isNotEmpty) { // Normal path.
            setState(() {
              _polylines = segmentedPolylines.toSet(); // Draw polylines.
              _routePoints = segmentedPolylines
                  .expand((p) => p.points)
                  .toList(growable: false); // Flatten for snapping.
              _isLoading = false; // Done loading.
            });
          } else { // Step data missing -> fallback to overview polyline.
            // Fallback to overview polyline if step data is missing
            final route = directions!['routes'][0];
            final String encodedPolyline = route['overview_polyline']['points'] as String; // Encoded polyline.
            final points = PolylineSimplifier.simplifyPolyline(
                decodePolyline(encodedPolyline), 10); // Decode and simplify.
            setState(() {
              _polylines = { // Single polyline fallback.
                Polyline(
                  polylineId: const PolylineId('route'),
                  points: points,
                  color: Colors.blue,
                  width: 4,
                )
              };
              _routePoints = points; // Flatten.
              _isLoading = false; // Done.
            });
          }
          _computeRouteLength(); // Compute total length.
          _transferBoundariesMeters.clear(); // No transfers expected for non-metro; ensure cleared.
          _buildStepBoundariesAndDurations(); // Step boundaries for ETA.
          _computeInitialMetrics(userLat, userLng); // Initial ETA/distance.
          _adjustCamera(userLat, userLng); // Fit camera.
        } catch (e) {
          if (mounted) {
            setState(() {
              _isLoading = false; // Stop spinner.
            });
            dev.log("Error processing directions data: $e", name: "MapTrackingScreen"); // Log.
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text("Error processing directions data: $e")), // User feedback.
            );
          }
        }
      }
    } else { // No directions provided.
      setState(() {
        _isLoading = false; // Stop spinner.
      });
      dev.log("No valid routes in directions data", name: "MapTrackingScreen"); // Log.
    }

    // Start listening for location updates to update the current location marker.
    _startLocationUpdates(); // Begin foreground updates.

    // Listen for route switches from TrackingService and show a banner.
    _routeSwitchSub ??= TrackingService().routeSwitchStream.listen((evt) { // Switch banner.
      if (!mounted) return; // Guard.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Switched route: ${evt.fromKey} → ${evt.toKey}')
        ),
      );
    });

    // Listen for continuous route state to compute ETA and remaining distance.
    _routeStateSub ??= TrackingService().activeRouteStateStream.listen((state) { // Update summary cards.
      if (!mounted) return; // Guard.
      // Remaining distance from manager
      final remainingM = state.remainingMeters; // Remaining meters provided by manager.
    // Derive ETA using a fallback speed; will be replaced by fusion/dead-reckoning later
      double etaSec; // Local ETA seconds.
      final fallbackSpeed = 12.0; // ~43 km/h; TODO: replace with fusion when ready
      etaSec = remainingM / fallbackSpeed; // Simple division.
      // Format
      String etaStr; // Human readable ETA.
      if (etaSec < 90) {
        etaStr = '${etaSec.toStringAsFixed(0)} sec remaining';
      } else if (etaSec < 3600) {
        etaStr = '${(etaSec / 60).toStringAsFixed(0)} min remaining';
      } else {
        etaStr = '${(etaSec / 3600).toStringAsFixed(1)} hr remaining';
      }
      String distStr = remainingM >= 1000
          ? '${(remainingM / 1000).toStringAsFixed(2)} km to destination'
          : '${remainingM.toStringAsFixed(0)} m to destination';

      String? switchMsg; // Upcoming transfer display.
      if (state.pendingSwitchToKey != null && state.pendingSwitchInSeconds != null) {
        final secs = state.pendingSwitchInSeconds!; // Seconds until switch.
        final when = secs < 60
            ? '${secs.toStringAsFixed(0)} sec'
            : '${(secs / 60).toStringAsFixed(0)} min'; // Humanize.
        switchMsg = "You'll have to switch routes in $when"; // Compose.
      }

      setState(() {
        _etaText = etaStr; // Apply ETA.
        _distanceText = distStr; // Apply distance.
        _switchNotice = switchMsg; // Apply notice.
      });
    });
  }

  Future<void> _startLocationUpdates() async { // Foreground GPS updates and snapping.
    // Use high accuracy updates in the foreground.
    LocationSettings settings = const LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 5, // Update when moved 5 meters.
    );
    _locationSubscription =
        Geolocator.getPositionStream(locationSettings: settings).listen((position) {
      _currentUserLocation = LatLng(position.latitude, position.longitude); // Store raw position.
      dev.log("MapTrackingScreen: New user location: (${position.latitude}, ${position.longitude})",
          name: "MapTrackingScreen"); // Log update.
      // Smooth speed estimate
      final rawSpeed = position.speed; // m/s
      if (rawSpeed.isFinite && rawSpeed >= 0) {
        final v = rawSpeed < 0.5 && _speedEmaMps != null ? _speedEmaMps! : rawSpeed; // Avoid overreacting to near-zero noise.
        _speedEmaMps = _speedEmaMps == null ? v : (_speedEmaMps! * 0.8 + v * 0.2); // EMA smoothing.
      }
      // Prefer snapped position onto the route if available
      LatLng markerPos = _currentUserLocation!; // Default marker position.
      if (_routePoints.length >= 2) { // Snap only when polyline ready.
        final snap = SnapToRouteEngine.snap(
          point: _currentUserLocation!,
          polyline: _routePoints,
          hintIndex: _lastSnapIndex,
          searchWindow: 30,
        );
        _lastSnapIndex = snap.segmentIndex; // Update hint.
        markerPos = snap.snappedPoint; // Snapped marker.
        // Compute remaining distance and ETA locally
        final progress = snap.progressMeters; // Meters progressed along polyline.
        final remaining = (_routeLengthMeters - progress).clamp(0.0, double.infinity); // Clamp non-negative.
        // Prefer ETA from directions step durations (no API) if available; fallback to speed-based
        double? etaSec = EtaUtils.etaRemainingSeconds(
          progressMeters: progress,
          stepBoundariesMeters: _stepBoundariesMeters,
          stepDurationsSeconds: _stepDurationsSeconds,
        );
        if (etaSec == null) {
          final spd = (_speedEmaMps != null && _speedEmaMps! > 0.5) ? _speedEmaMps! : 12.0; // Fallback speed.
          etaSec = remaining / spd; // Simple estimate.
        }
        final etaStr = etaSec < 90
            ? '${etaSec.toStringAsFixed(0)} sec remaining'
            : etaSec < 3600
                ? '${(etaSec / 60).toStringAsFixed(0)} min remaining'
                : '${(etaSec / 3600).toStringAsFixed(1)} hr remaining'; // Format.
        final distStr = remaining >= 1000
            ? '${(remaining / 1000).toStringAsFixed(2)} km to destination'
            : '${remaining.toStringAsFixed(0)} m to destination'; // Format.

        String? switchMsg; // Next transfer banner.
        if (_transferBoundariesMeters.isNotEmpty) {
          final next = _transferBoundariesMeters.firstWhere(
            (b) => b > progress,
            orElse: () => -1,
          );
          if (next > 0) {
            final toSwitchM = next - progress; // Meters until next transfer.
            final spd = (_speedEmaMps != null && _speedEmaMps! > 0.5) ? _speedEmaMps! : 12.0; // Fallback speed.
            final tSec = toSwitchM / spd; // Seconds to transfer.
            final when = tSec < 60 ? '${tSec.toStringAsFixed(0)} sec' : '${(tSec / 60).toStringAsFixed(0)} min'; // Humanize.
            switchMsg = "You'll have to switch routes in $when"; // Compose.
          }
        }
        if (mounted) {
          setState(() {
            _etaText = etaStr; // Update.
            _distanceText = distStr; // Update.
            _switchNotice = switchMsg; // Update.
            // metrics ready // Marker update below.
          });
        }
      }
      // Update the marker for current (snapped) location.
      setState(() {
        _markers.removeWhere((m) => m.markerId.value == 'currentLocationMarker'); // Remove old marker.
        _markers.add(Marker(
          markerId: const MarkerId('currentLocationMarker'),
          position: markerPos, // Either raw or snapped.
          infoWindow: const InfoWindow(title: 'Your Location'),
        ));
      });
    });
  }

  void _computeInitialMetrics(double userLat, double userLng) { // First draw ETA/distance after building route.
    if (_routePoints.length < 2) return; // Require polyline.
    final p = LatLng(userLat, userLng); // Current position.
    final snap = SnapToRouteEngine.snap(point: p, polyline: _routePoints, hintIndex: null, searchWindow: 30); // Snap to route.
    final progress = snap.progressMeters; // Meters progressed.
    final remaining = (_routeLengthMeters - progress).clamp(0.0, double.infinity); // Remaining meters.
    double? etaSec = EtaUtils.etaRemainingSeconds(
      progressMeters: progress,
      stepBoundariesMeters: _stepBoundariesMeters,
      stepDurationsSeconds: _stepDurationsSeconds,
    );
    if (etaSec == null) {
      final spd = 12.0; // Fallback speed.
      etaSec = remaining / spd; // Simple ETA.
    }
    final etaStr = etaSec < 90
        ? '${etaSec.toStringAsFixed(0)} sec remaining'
        : etaSec < 3600
            ? '${(etaSec / 60).toStringAsFixed(0)} min remaining'
            : '${(etaSec / 3600).toStringAsFixed(1)} hr remaining';
    final distStr = remaining >= 1000
        ? '${(remaining / 1000).toStringAsFixed(2)} km to destination'
        : '${remaining.toStringAsFixed(0)} m to destination';
    String? switchMsg; // Next transfer message.
    if (_transferBoundariesMeters.isNotEmpty) {
      final next = _transferBoundariesMeters.firstWhere((b) => b > progress, orElse: () => -1); // Find next.
      if (next > 0) {
        final toSwitchM = next - progress; // Meters to transfer.
        final spd = 12.0; // Fallback speed for initial estimation.
        final tSec = toSwitchM / spd; // Seconds.
        final when = tSec < 60 ? '${tSec.toStringAsFixed(0)} sec' : '${(tSec / 60).toStringAsFixed(0)} min'; // Humanize.
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

  void _computeRouteLength() { // Sum segments of polyline in meters.
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

  void _buildTransferBoundariesFromDirections() { // Populate transfer boundaries for metro notifications.
    _transferBoundariesMeters
      ..clear()
      ..addAll(TransferUtils.buildTransferBoundariesMeters(directions!, metroMode: _metroMode)); // Compute from directions.
  }

  void _buildStepBoundariesAndDurations() { // Prepare step cumulative meters and durations for ETA interpolation.
    _stepBoundariesMeters.clear(); // Reset.
    _stepDurationsSeconds.clear(); // Reset.
    if (directions == null) return; // Require directions.
    try {
      final routes = (directions!['routes'] as List?) ?? const []; // Safe routes.
      if (routes.isEmpty) return; // No routes.
      final route = routes.first as Map<String, dynamic>; // Use first route.
      final legs = (route['legs'] as List?) ?? const []; // Legs list.
      double cum = 0.0; // Cumulative meters.
      for (final leg in legs) {
        final steps = (leg['steps'] as List?) ?? const []; // Steps list.
        for (final step in steps) {
          final m = ((step['distance'] as Map<String, dynamic>?)?['value']) as num?; // Step meters.
          final s = ((step['duration'] as Map<String, dynamic>?)?['value']) as num?; // Step seconds.
          if (m != null && s != null) {
            cum += m.toDouble(); // Increment cumulative.
            _stepBoundariesMeters.add(cum); // Record boundary.
            _stepDurationsSeconds.add(s.toDouble()); // Record duration.
          }
        }
      }
    } catch (_) {} // Ignore parse errors; will fallback ETA.
  }

  Future<void> _adjustCamera(double userLat, double userLng) async { // Fit camera to user and destination.
    final GoogleMapController controller = await _mapController.future; // Await controller.
    if (_destinationLat == null || _destinationLng == null) return; // Require destination.
    final bounds = LatLngBounds(
      southwest: LatLng(min(userLat, _destinationLat!), min(userLng, _destinationLng!)), // SW corner.
      northeast: LatLng(max(userLat, _destinationLat!), max(userLng, _destinationLng!)), // NE corner.
    );
    controller.animateCamera(CameraUpdate.newLatLngBounds(bounds, 50)); // Apply with padding.
  }

  @override
  void dispose() { // Clean up streams and controllers.
    _locationSubscription?.cancel(); // Stop GPS stream.
    _routeSwitchSub?.cancel(); // Stop switch stream.
    _routeStateSub?.cancel(); // Stop state stream.
    super.dispose(); // Parent cleanup.
  }

  @override
  Widget build(BuildContext context) { // Compose the map tracking UI.
    if (!_hasValidArgs) { // If args missing, show simple error.
      return Scaffold(
        appBar: AppBar(title: const Text("Map Tracking")),
        body: const Center(child: Text("Invalid or missing destination data.")),
      );
    }
    return PopScope( // Intercept back button.
      canPop: false, // Prevent pop.
      onPopInvokedWithResult: (bool didPop, dynamic result) async { // Back handler.
        if (!didPop) {
          // Handle the back button press here if needed
          // For now, we'll just prevent the pop since canPop is false
        }
      },
      child: Scaffold(
        drawer: const SettingsDrawer(), // Drawer.
        appBar: AppBar(
          title: Row(
            children: [
              Text(
                _metroMode ? 'Metro Tracking' : 'Map Tracking', // Title toggles with mode.
                style: GoogleFonts.pacifico(
                  textStyle: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 26,
                  ),
                ),
              ),
              if (_metroMode) ...[
                const SizedBox(width: 8),
                const Icon(Icons.train), // Mode icon.
              ],
            ],
          ),
        ),
        bottomNavigationBar: Container(
          height: 50,
          color: Colors.grey[300],
          child: const Center(child: Text('Ad Banner Placeholder')), // Stub ad.
        ),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: Stack(
                  children: [
                    GoogleMap(
                      initialCameraPosition: CameraPosition(
                        target: LatLng(_destinationLat!, _destinationLng!), // Start view at destination.
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
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
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
                      const Center(child: CircularProgressIndicator()), // Spinner overlay.
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
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                        ),
                        if (!_etaText.contains('remaining')) ...[
                          const SizedBox(width: 8),
                          const PulsingDots(color: Colors.grey), // Loading indicator near ETA.
                        ]
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          _distanceText,
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                        ),
                        if (!_distanceText.contains('to destination')) ...[
                          const SizedBox(width: 8),
                          const PulsingDots(color: Colors.grey), // Loading indicator near distance.
                        ]
                      ],
                    ),
                    if (_switchNotice != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        _switchNotice!,
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: Colors.orange),
                      ),
                    ],
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        // Stop Alarm Button - only visible when alarm is playing
                        Expanded(
                          child: ValueListenableBuilder<bool>(
                            valueListenable: AlarmPlayer.isPlaying, // Listen to alarm state.
                            builder: (context, playing, child) {
                              final cs = Theme.of(context).colorScheme; // Theme colors.
                              return ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: cs.secondaryContainer,
                                  foregroundColor: cs.onSecondaryContainer,
                                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                                  textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                                  disabledBackgroundColor: Colors.grey.shade300,
                                  disabledForegroundColor: Colors.grey.shade600,
                                ),
                                onPressed: playing ? () async {
                                  await AlarmPlayer.stop(); // Stop sound.
                                  try {
                                    // Also notify the background service
                                    final service = FlutterBackgroundService();
                                    service.invoke('stopAlarm'); // Ask service to stop vibration etc.
                                  } catch (e) {
                                    dev.log('Failed to send stopAlarm to service: $e', name: 'MapTracking');
                                  }
                                } : null, // Button disabled when alarm not playing
                                icon: const Icon(Icons.notifications_off, size: 24),
                                label: const Text('STOP ALARM'),
                              );
                            },
                          ),
                        ),
                        const SizedBox(width: 8), // Spacing between buttons
                        // End Tracking Button
                        Expanded(
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Theme.of(context).colorScheme.error,
                              foregroundColor: Theme.of(context).colorScheme.onError,
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                              textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                            ),
                            onPressed: () async {
                              // Stop alarm sounds and vibration
                              await AlarmPlayer.stop();
                              
                              // Stop tracking service
                              await TrackingService().stopTracking();
                              
                              // Cancel notifications through notification service
                              try {
                                await NotificationService().cancelJourneyProgress();
                              } catch (e) {
                                dev.log('Error cancelling notifications: $e', name: 'MapTracking');
                              }
                              
                              // Navigate back to home screen
                              Navigator.pushReplacementNamed(context, '/');
                            },
                            icon: const Icon(Icons.stop_circle_outlined, size: 24),
                            label: const Text('END TRACKING'),
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

class _LegendItem extends StatelessWidget { // Small legend chip for route types.
  final Color color; // Line color.
  final bool dashed; // Dashed or solid.
  final String label; // Text label.
  const _LegendItem({required this.color, required this.dashed, required this.label});

  @override
  Widget build(BuildContext context) { // Render chip.
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        CustomPaint(
          painter: _LineSamplePainter(color: color, dashed: dashed), // Draw line sample.
          size: const Size(28, 6), // Sample size.
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: const TextStyle(color: Colors.white, fontSize: 12), // White small text.
        ),
      ],
    );
  }
}

class _LineSamplePainter extends CustomPainter { // Paints a solid or dashed line sample.
  final Color color; // Paint color.
  final bool dashed; // Whether to draw dashes.
  _LineSamplePainter({required this.color, required this.dashed});

  @override
  void paint(Canvas canvas, Size size) { // Draw on canvas.
    final paint = Paint()
      ..color = color
      ..strokeWidth = 4
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round; // Rounded ends.
    final y = size.height / 2; // Center y.
    if (!dashed) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint); // Single solid line.
    } else {
      const double dashWidth = 8.0; // Dash length.
      const double dashSpace = 6.0; // Space length.
      double x = 0.0; // Cursor.
      while (x < size.width) { // Repeat dashes.
        final double x2 = (x + dashWidth) > size.width ? size.width : (x + dashWidth); // Clip last dash.
        canvas.drawLine(Offset(x, y), Offset(x2, y), paint); // Draw dash.
        x += dashWidth + dashSpace; // Advance.
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false; // No repaint needed.
}

// Post-block notes:
// - Segmented polylines are preferred for styling and transfer boundary detection; overview polyline is a fallback.
// - Snapping to route yields stable progress and distance metrics; EMA of speed smooths noisy GPS speed.
// - ETA prioritizes stepwise durations when present; otherwise speed-based.
// - UI exposes STOP ALARM and END TRACKING controls; background service notified to cease vibration.
// - Camera bounds fit user and destination; legend overlay communicates segment types.

// End-of-file summary:
// - This screen visualizes and manages live tracking, computing and presenting ETA, distance, and upcoming transfers.
// - Integrates with TrackingService streams for route switches and state; cleans up subscriptions.
// - Uses defensive guards on `mounted` and argument presence to avoid runtime errors.
