import 'dart:async';
import 'dart:math';
import 'dart:developer' as dev;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geowake2/services/polyline_decoder.dart';
import 'package:geowake2/services/direction_service.dart';
import 'package:geowake2/services/polyline_simplifier.dart';
import 'package:geolocator/geolocator.dart';
import 'settingsdrawer.dart';
import 'package:geowake2/services/snap_to_route.dart';
import 'package:geowake2/services/trackingservice.dart';
import 'package:geowake2/services/active_route_manager.dart';
import 'package:geowake2/services/transfer_utils.dart';
import 'package:geowake2/widgets/pulsing_dots.dart';
import 'package:geowake2/services/eta_utils.dart';
import 'package:geowake2/services/alarm_player.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geowake2/services/tracking_state_store.dart';
import 'package:geowake2/config/power_policy.dart';
import 'package:battery_plus/battery_plus.dart';

class MapTrackingScreen extends StatefulWidget {
  MapTrackingScreen({Key? key}) : super(key: key);
  @override
  State<MapTrackingScreen> createState() => _MapTrackingScreenState();
}

class _MapTrackingScreenState extends State<MapTrackingScreen> {
  final Completer<GoogleMapController> _mapController = Completer();
  bool _isLoading = true;
  double? _destinationLat;
  double? _destinationLng;
  String? _destinationName;
  LatLng? _currentUserLocation;
  List<LatLng> _routePoints = const [];
  int? _lastSnapIndex;
  StreamSubscription<RouteSwitchEvent>? _routeSwitchSub;
  StreamSubscription<ActiveRouteState>? _routeStateSub;
  StreamSubscription<Position>? _locationSubscription; // Restored
  double _routeLengthMeters = 0.0;
  double? _speedEmaMps; // simple smoothed speed estimate
  final List<double> _transferBoundariesMeters = [];
  final List<double> _stepBoundariesMeters = [];
  final List<double> _stepDurationsSeconds = [];

  // Restored missing variables
  String? _switchNotice;
  bool _hasValidArgs = false;
  String _alarmMode = 'distance';
  bool _metroMode = false;
  Set<Marker> _markers = {};
  Set<Polyline> _polylines = {};
  String _etaText = "Calculating ETA...";
  String _distanceText = "Calculating distance...";
  Map<String, dynamic>? directions;
  bool _isFinalAlarm = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final args =
        ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;
    dev.log(
      "MapTrackingScreen received args: ${args.toString()}",
      name: "MapTrackingScreen",
    );

    if (args == null) {
      // Try to restore from SharedPreferences
      _restoreState();
      return;
    }

    if (args['lat'] == null ||
        args['lng'] == null ||
        args['destination'] == null ||
        args['directions'] == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
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
      return;
    }
    _hasValidArgs = true;
    _destinationName = args['destination'];
    _destinationLat = args['lat'];
    _destinationLng = args['lng'];
    _metroMode = args['metroMode'] ?? false;
    _alarmMode = args['alarmMode'] ?? 'distance';
    double userLat = args['userLat'] ?? 37.422;
    double userLng = args['userLng'] ?? -122.084;
    _currentUserLocation = LatLng(userLat, userLng);
    dev.log(
      "MapTrackingScreen: Destination: $_destinationName, ($_destinationLat, $_destinationLng)",
      name: "MapTrackingScreen",
    );
    dev.log(
      "MapTrackingScreen: Initial user location: ($userLat, $userLng)",
      name: "MapTrackingScreen",
    );

    _markers = {
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

    _etaText = args['eta']?.toString() ?? _etaText;
    _distanceText = args['distance']?.toString() ?? _distanceText;
    directions = args['directions'];
    _processDirections(userLat, userLng);

    // Start listening for location updates to update the current location marker.
    _startLocationUpdates();

    // Listen for route switches from TrackingService and show a banner + update map.
    _routeSwitchSub ??= TrackingService().routeSwitchStream.listen((evt) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Switched route: ${evt.fromKey} → ${evt.toKey}'),
        ),
      );

      if (evt.geometry != null && evt.geometry!.isNotEmpty) {
        dev.log(
          'MapTrackingScreen: Updating map for switched route ${evt.toKey}',
          name: 'MapTrackingScreen',
        );
        setState(() {
          _routePoints = evt.geometry!;
          _polylines = {
            Polyline(
              polylineId: const PolylineId('route'),
              points: _routePoints,
              color: Colors.blue,
              width: 4,
            ),
          };
        });
        // Recompute metrics for the new route
        _computeRouteLength();
        if (_currentUserLocation != null) {
          _computeInitialMetrics(
            _currentUserLocation!.latitude,
            _currentUserLocation!.longitude,
          );
        }
      }
    });

    // Listen for continuous route state to compute ETA and remaining distance.
    _routeStateSub ??= TrackingService().activeRouteStateStream.listen((state) {
      if (!mounted) return;
      // Remaining distance from manager
      final remainingM = state.remainingMeters;
      // Derive ETA using a fallback speed; will be replaced by fusion/dead-reckoning later
      double etaSec;
      final fallbackSpeed =
          12.0; // ~43 km/h; TODO: replace with fusion when ready
      etaSec = remainingM / fallbackSpeed;
      // Format
      String etaStr;
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

      String? switchMsg;
      if (state.pendingSwitchToKey != null &&
          state.pendingSwitchInSeconds != null) {
        final secs = state.pendingSwitchInSeconds!;
        final when =
            secs < 60
                ? '${secs.toStringAsFixed(0)} sec'
                : '${(secs / 60).toStringAsFixed(0)} min';
        switchMsg = "You'll have to switch routes in $when";
      }

      setState(() {
        _etaText = etaStr;
        _distanceText = distStr;
        _switchNotice = switchMsg;
      });
    });
  }

  Future<void> _restoreState() async {
    dev.log(
      'DEBUG: maptracking - _restoreState called',
      name: 'MapTrackingScreen',
    );
    try {
      final active = await TrackingStateStore.isActive();
      final snapshot = await TrackingStateStore.loadSnapshot();
      dev.log(
        'DEBUG: maptracking - active: $active, snapshot exists: ${snapshot != null}',
        name: 'MapTrackingScreen',
      );
      if (snapshot != null) {
        dev.log(
          'DEBUG: maptracking - snapshot details: dest=${snapshot.destinationName}, directions=${snapshot.directions != null ? "exists" : "null"}',
          name: 'MapTrackingScreen',
        );
      }
      if (!active || snapshot == null) {
        dev.log(
          'DEBUG: maptracking - redirecting to home: active=$active, snapshot=${snapshot != null}',
          name: 'MapTrackingScreen',
        );
        if (mounted) Navigator.of(context).pushReplacementNamed('/');
        return;
      }

      setState(() {
        _destinationLat = snapshot.destinationLat;
        _destinationLng = snapshot.destinationLng;
        _destinationName = snapshot.destinationName;
        _metroMode = snapshot.metroMode;
        _alarmMode = snapshot.alarmMode;
        directions = snapshot.directions;
        _hasValidArgs = true;
      });

      _currentUserLocation = LatLng(snapshot.userLat, snapshot.userLng);

      // If directions are missing, fetch fresh route
      if (directions == null) {
        dev.log(
          'DEBUG: maptracking - Directions missing in snapshot, fetching fresh route',
          name: 'MapTrackingScreen',
        );
        try {
          final newDirections = await DirectionService().getDirections(
            _currentUserLocation!.latitude,
            _currentUserLocation!.longitude,
            snapshot.destinationLat,
            snapshot.destinationLng,
            isDistanceMode: _alarmMode == 'distance' || _alarmMode == 'stops',
            threshold: snapshot.alarmValue,
            transitMode: _metroMode,
          );
          dev.log(
            'DEBUG: maptracking - Fresh directions fetched successfully',
            name: 'MapTrackingScreen',
          );
          setState(() {
            directions = newDirections;
          });
          // Update snapshot with fresh directions
          await TrackingStateStore.saveSnapshot(
            TrackingSnapshot(
              destinationName: snapshot.destinationName,
              destinationLat: snapshot.destinationLat,
              destinationLng: snapshot.destinationLng,
              alarmMode: snapshot.alarmMode,
              alarmValue: snapshot.alarmValue,
              metroMode: snapshot.metroMode,
              userLat: snapshot.userLat,
              userLng: snapshot.userLng,
              createdAt: snapshot.createdAt,
              directions: newDirections,
            ),
          );
        } catch (e) {
          dev.log(
            'Failed to fetch fresh route on restore: $e',
            name: 'MapTrackingScreen',
          );
        }
      }

      // Initialize markers
      _markers = {
        if (_destinationLat != null && _destinationLng != null)
          Marker(
            markerId: const MarkerId('destinationMarker'),
            position: LatLng(_destinationLat!, _destinationLng!),
            infoWindow: InfoWindow(title: _destinationName ?? 'Destination'),
          ),
        Marker(
          markerId: const MarkerId('currentLocationMarker'),
          position: _currentUserLocation!,
          infoWindow: const InfoWindow(title: 'Your Location'),
        ),
      };

      _isLoading = false;
      _processDirections(
        _currentUserLocation!.latitude,
        _currentUserLocation!.longitude,
      );
      _adjustCamera(
        _currentUserLocation!.latitude,
        _currentUserLocation!.longitude,
      );
      _startLocationUpdates();

      // Re-subscribe to tracking service streams
      _routeSwitchSub ??= TrackingService().routeSwitchStream.listen((evt) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Switched route: ${evt.fromKey} → ${evt.toKey}'),
          ),
        );
      });

      _routeStateSub ??= TrackingService().activeRouteStateStream.listen((
        state,
      ) {
        if (!mounted) return;
        final remainingM = state.remainingMeters;
        double etaSec;
        final fallbackSpeed = 12.0;
        etaSec = remainingM / fallbackSpeed;
        String etaStr;
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

        setState(() {
          _etaText = etaStr;
          _distanceText = distStr;
          _isFinalAlarm = state.isFinalAlarm;
        });
      });
    } catch (e) {
      dev.log("Error restoring state: $e", name: "MapTrackingScreen");
      if (mounted) Navigator.of(context).pushReplacementNamed('/');
    }
  }

  void _processDirections(double userLat, double userLng) {
    if (directions != null) {
      if (_metroMode) {
        final directionService = DirectionService();
        final segmentedPolylines = directionService.buildSegmentedPolylines(
          directions!,
          true,
        );
        setState(() {
          _polylines = segmentedPolylines.toSet();
          _routePoints = segmentedPolylines
              .expand((p) => p.points)
              .toList(growable: false);
          _isLoading = false;
        });
        _computeRouteLength();
        _buildTransferBoundariesFromDirections();
        _buildStepBoundariesAndDurations();
        _computeInitialMetrics(userLat, userLng);
        _adjustCamera(userLat, userLng);
      } else {
        try {
          final directionService = DirectionService();
          final segmentedPolylines = directionService.buildSegmentedPolylines(
            directions!,
            false,
          );
          if (segmentedPolylines.isNotEmpty) {
            setState(() {
              _polylines = segmentedPolylines.toSet();
              _routePoints = segmentedPolylines
                  .expand((p) => p.points)
                  .toList(growable: false);
              _isLoading = false;
            });
          } else {
            final route = directions!['routes'][0];
            final String encodedPolyline =
                route['overview_polyline']['points'] as String;
            final points = PolylineSimplifier.simplifyPolyline(
              decodePolyline(encodedPolyline),
              10,
            );
            setState(() {
              _polylines = {
                Polyline(
                  polylineId: const PolylineId('route'),
                  points: points,
                  color: Colors.blue,
                  width: 4,
                ),
              };
              _routePoints = points;
              _isLoading = false;
            });
          }
          _computeRouteLength();
          _transferBoundariesMeters.clear();
          _buildStepBoundariesAndDurations();
          _computeInitialMetrics(userLat, userLng);
          _adjustCamera(userLat, userLng);
        } catch (e) {
          if (mounted) {
            setState(() {
              _isLoading = false;
            });
            dev.log(
              "Error processing directions data: $e",
              name: "MapTrackingScreen",
            );
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text("Error processing directions data: $e")),
            );
          }
        }
      }
    } else {
      setState(() {
        _isLoading = false;
      });
      dev.log("No valid routes in directions data", name: "MapTrackingScreen");
    }
  }

  Future<void> _startLocationUpdates() async {
    // Use PowerPolicy for dynamic location settings
    final battery = Battery();
    int batteryLevel = 100;
    try {
      batteryLevel = await battery.batteryLevel;
    } catch (_) {}

    final policy = PowerPolicyManager.forBatteryLevel(batteryLevel);

    LocationSettings settings = LocationSettings(
      accuracy: policy.accuracy,
      distanceFilter: policy.distanceFilterMeters,
    );

    dev.log(
      'Starting location updates with filter: ${policy.distanceFilterMeters}m',
      name: 'MapTrackingScreen',
    );

    _locationSubscription = Geolocator.getPositionStream(
      locationSettings: settings,
    ).listen((position) {
      _currentUserLocation = LatLng(position.latitude, position.longitude);
      dev.log(
        "MapTrackingScreen: New user location: (${position.latitude}, ${position.longitude})",
        name: "MapTrackingScreen",
      );
      // Smooth speed estimate
      final rawSpeed = position.speed; // m/s
      if (rawSpeed.isFinite && rawSpeed >= 0) {
        final v =
            rawSpeed < 0.5 && _speedEmaMps != null ? _speedEmaMps! : rawSpeed;
        _speedEmaMps =
            _speedEmaMps == null ? v : (_speedEmaMps! * 0.8 + v * 0.2);
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
        // Prefer ETA from directions step durations (no API) if available; fallback to speed-based
        double? etaSec = EtaUtils.etaRemainingSeconds(
          progressMeters: progress,
          stepBoundariesMeters: _stepBoundariesMeters,
          stepDurationsSeconds: _stepDurationsSeconds,
        );
        if (etaSec == null) {
          final spd =
              (_speedEmaMps != null && _speedEmaMps! > 0.5)
                  ? _speedEmaMps!
                  : 12.0;
          etaSec = remaining / spd;
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
                    : 12.0;
            final tSec = toSwitchM / spd;
            final when =
                tSec < 60
                    ? '${tSec.toStringAsFixed(0)} sec'
                    : '${(tSec / 60).toStringAsFixed(0)} min';
            switchMsg = "You'll have to switch routes in $when";
          }
        }
        if (mounted) {
          setState(() {
            _etaText = etaStr;
            _distanceText = distStr;
            _switchNotice = switchMsg;
            // metrics ready
          });
        }
      }
      // Update the marker for current (snapped) location.
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
    });
  }

  void _computeInitialMetrics(double userLat, double userLng) {
    if (_routePoints.length < 2) return;
    final p = LatLng(userLat, userLng);
    final snap = SnapToRouteEngine.snap(
      point: p,
      polyline: _routePoints,
      hintIndex: null,
      searchWindow: 30,
    );
    final progress = snap.progressMeters;
    final remaining = (_routeLengthMeters - progress).clamp(
      0.0,
      double.infinity,
    );
    double? etaSec = EtaUtils.etaRemainingSeconds(
      progressMeters: progress,
      stepBoundariesMeters: _stepBoundariesMeters,
      stepDurationsSeconds: _stepDurationsSeconds,
    );
    if (etaSec == null) {
      final spd = 12.0;
      etaSec = remaining / spd;
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
        final spd = 12.0;
        final tSec = toSwitchM / spd;
        final when =
            tSec < 60
                ? '${tSec.toStringAsFixed(0)} sec'
                : '${(tSec / 60).toStringAsFixed(0)} min';
        switchMsg = "You'll have to switch routes in $when";
      }
    }
    if (mounted) {
      setState(() {
        _etaText = etaStr;
        _distanceText = distStr;
        _switchNotice = switchMsg;
        // metrics ready
      });
    }
  }

  void _computeRouteLength() {
    double sum = 0.0;
    for (var i = 1; i < _routePoints.length; i++) {
      sum += Geolocator.distanceBetween(
        _routePoints[i - 1].latitude,
        _routePoints[i - 1].longitude,
        _routePoints[i].latitude,
        _routePoints[i].longitude,
      );
    }
    _routeLengthMeters = sum;
  }

  void _buildTransferBoundariesFromDirections() {
    _transferBoundariesMeters
      ..clear()
      ..addAll(
        TransferUtils.buildTransferBoundariesMeters(
          directions!,
          metroMode: _metroMode,
        ),
      );
  }

  void _buildStepBoundariesAndDurations() {
    _stepBoundariesMeters.clear();
    _stepDurationsSeconds.clear();
    if (directions == null) return;
    try {
      final routes = (directions!['routes'] as List?) ?? const [];
      if (routes.isEmpty) return;
      final route = routes.first as Map<String, dynamic>;
      final legs = (route['legs'] as List?) ?? const [];
      double cum = 0.0;
      for (final leg in legs) {
        final steps = (leg['steps'] as List?) ?? const [];
        for (final step in steps) {
          final m =
              ((step['distance'] as Map<String, dynamic>?)?['value']) as num?;
          final s =
              ((step['duration'] as Map<String, dynamic>?)?['value']) as num?;
          if (m != null && s != null) {
            cum += m.toDouble();
            _stepBoundariesMeters.add(cum);
            _stepDurationsSeconds.add(s.toDouble());
          }
        }
      }
    } catch (_) {}
  }

  Future<void> _adjustCamera(double userLat, double userLng) async {
    final GoogleMapController controller = await _mapController.future;
    if (_destinationLat == null || _destinationLng == null) return;
    final bounds = LatLngBounds(
      southwest: LatLng(
        min(userLat, _destinationLat!),
        min(userLng, _destinationLng!),
      ),
      northeast: LatLng(
        max(userLat, _destinationLat!),
        max(userLng, _destinationLng!),
      ),
    );
    controller.animateCamera(CameraUpdate.newLatLngBounds(bounds, 50));
  }

  @override
  void dispose() {
    _locationSubscription?.cancel();
    _routeSwitchSub?.cancel();
    _routeStateSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_hasValidArgs) {
      return Scaffold(
        appBar: AppBar(title: const Text("Map Tracking")),
        body: const Center(child: Text("Invalid or missing destination data.")),
      );
    }
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, dynamic result) async {
        if (!didPop) {
          // Handle the back button press here if needed
          // For now, we'll just prevent the pop since canPop is false
        }
      },
      child: Scaffold(
        drawer: const SettingsDrawer(),
        appBar: AppBar(
          title: Row(
            children: [
              Text(
                _metroMode ? 'Metro Tracking' : 'Map Tracking',
                style: GoogleFonts.pacifico(
                  textStyle: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 26,
                  ),
                ),
              ),
              if (_metroMode) ...[
                const SizedBox(width: 8),
                const Icon(Icons.train),
              ],
            ],
          ),
        ),
        bottomNavigationBar: Container(
          height: 50,
          color: Colors.grey[300],
          child: const Center(child: Text('Ad Banner Placeholder')),
        ),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: Stack(
                  children: [
                    GoogleMap(
                      initialCameraPosition: CameraPosition(
                        target: LatLng(_destinationLat!, _destinationLng!),
                        zoom: 14,
                      ),
                      markers: _markers,
                      polylines: _polylines,
                      onMapCreated: (controller) {
                        if (!_mapController.isCompleted) {
                          _mapController.complete(controller);
                        }
                      },
                    ),
                    // Route legend overlay (compact, avoids overflow)
                    Positioned(
                      top: 12,
                      left: 12,
                      right: 12,
                      child: Material(
                        color: Colors.black.withOpacity(0.5),
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
                      const Center(child: CircularProgressIndicator()),
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
                          const PulsingDots(color: Colors.grey),
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
                          const PulsingDots(color: Colors.grey),
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
                    Row(
                      children: [
                        // Stop Alarm Button - only visible when alarm is playing
                        // Stop Alarm Button - only visible when alarm is playing AND NOT final destination
                        // We assume 'distance' and 'time' are final destination alarms.
                        // 'stops' might be intermediate, so we allow stopping the alarm.
                        // Stop Alarm Button - visible whenever alarm is playing
                        ValueListenableBuilder<bool>(
                          valueListenable: AlarmPlayer.isPlaying,
                          builder: (context, playing, child) {
                            if (!playing) return const SizedBox.shrink();

                            // HIDE STOP ALARM BUTTON FOR FINAL DESTINATION
                            // The user requested only "End Tracking" be available.
                            // We check the latest route state (if active) or rely on heuristics?
                            // Better: We should have access to the latest ActiveRouteState via stream.
                            // But here we are inside a ValueListenableBuilder for playing.
                            // We can use a StreamBuilder for ActiveRouteState or store it in state.
                            // Actually, simply check if the current active alarm is 'destination'.
                            // But AlarmPlayer doesn't expose type.
                            // Hence we updated ActiveRouteState.
                            // We need to access the boolean from the state.
                            // Let's assume we store the latest 'isFinalAlarm' in a member variable from the stream listener.

                            // Re-reading logic: _routeStateSub listener updates UI state?
                            // Line 312: _routeStateSub updates _etaText, _distanceText.
                            // I should update a local field `_isFinalAlarm` there too.

                            if (_isFinalAlarm) return const SizedBox.shrink();

                            final cs = Theme.of(context).colorScheme;
                            return Expanded(
                              child: Padding(
                                padding: const EdgeInsets.only(right: 8.0),
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
                                  ),
                                  onPressed: () async {
                                    await AlarmPlayer.stop();
                                    try {
                                      // Also notify the background service
                                      final service =
                                          FlutterBackgroundService();
                                      service.invoke('stopAlarm');
                                    } catch (e) {
                                      dev.log(
                                        'Failed to send stopAlarm to service: $e',
                                        name: 'MapTracking',
                                      );
                                    }
                                  },
                                  icon: const Icon(
                                    Icons.notifications_off,
                                    size: 24,
                                  ),
                                  label: const Text('STOP ALARM'),
                                ),
                              ),
                            );
                          },
                        ),
                        if (_alarmMode == 'stops')
                          const SizedBox(width: 8), // Spacing between buttons
                        // End Tracking Button
                        Expanded(
                          child: Builder(
                            builder: (context) {
                              final isDark =
                                  Theme.of(context).brightness ==
                                  Brightness.dark;
                              // Use a softer red in dark mode for better aesthetics
                              final bgColor =
                                  isDark
                                      ? const Color(
                                        0xFFCF6679,
                                      ) // Material Dark Error
                                      : Theme.of(context).colorScheme.error;
                              final fgColor =
                                  isDark
                                      ? Colors.black
                                      : Theme.of(context).colorScheme.onError;

                              return ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: bgColor,
                                  foregroundColor: fgColor,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 16,
                                  ),
                                  textStyle: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                onPressed: () async {
                                  // Stop alarm sounds and vibration
                                  await AlarmPlayer.stop();

                                  await TrackingService().completeEndTracking();

                                  // Ensure we return to home even if the global navigator is null
                                  try {
                                    if (mounted) {
                                      Navigator.of(
                                        context,
                                      ).pushNamedAndRemoveUntil(
                                        '/',
                                        (route) => false,
                                      );
                                    }
                                  } catch (_) {}
                                },
                                icon: const Icon(
                                  Icons.stop_circle_outlined,
                                  size: 24,
                                ),
                                label: const Text('END TRACKING'),
                              );
                            },
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
  final Color color;
  final bool dashed;
  final String label;
  const _LegendItem({
    required this.color,
    required this.dashed,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        CustomPaint(
          painter: _LineSamplePainter(color: color, dashed: dashed),
          size: const Size(28, 6),
        ),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(color: Colors.white, fontSize: 12)),
      ],
    );
  }
}

class _LineSamplePainter extends CustomPainter {
  final Color color;
  final bool dashed;
  _LineSamplePainter({required this.color, required this.dashed});

  @override
  void paint(Canvas canvas, Size size) {
    final paint =
        Paint()
          ..color = color
          ..strokeWidth = 4
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round;
    final y = size.height / 2;
    if (!dashed) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    } else {
      const double dashWidth = 8.0;
      const double dashSpace = 6.0;
      double x = 0.0;
      while (x < size.width) {
        final double x2 =
            (x + dashWidth) > size.width ? size.width : (x + dashWidth);
        canvas.drawLine(Offset(x, y), Offset(x2, y), paint);
        x += dashWidth + dashSpace;
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
