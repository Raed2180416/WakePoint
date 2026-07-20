import 'dart:async';
import 'dart:developer' as dev;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geowake2/services/permission_service.dart';
import 'package:geowake2/services/reliability/reliability_preflight_runner.dart';
import 'package:geowake2/services/monetization/ad_policy.dart';
import 'package:geowake2/widgets/gated_banner_ad.dart';
import 'package:geowake2/screens/otherimpservices/recent_locations_service.dart';
import 'package:geowake2/services/saved_routes_service.dart';
import 'package:geowake2/services/saved_route.dart';
import 'package:geowake2/services/places_service.dart';
import 'package:geowake2/services/metro_stop_service.dart';
import 'package:geowake2/services/stop_logic_engine.dart';
import 'package:geowake2/services/transfer_utils.dart';
import 'settingsdrawer.dart';
import 'package:geowake2/services/trackingservice.dart';
import 'package:geowake2/services/share/guardian_service.dart';
import 'package:geowake2/services/widget/widget_arm_handler.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:geowake2/services/api_client.dart';
// import 'package:geowake2/services/direction_service.dart';
import 'package:geowake2/services/offline_coordinator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:geowake2/services/tracking_state_store.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  HomeScreenState createState() => HomeScreenState();
}

class HomeScreenState extends State<HomeScreen> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  Timer? _debounce;
  String? _currentCountryCode;

  List<Map<String, dynamic>> _recentLocations = [];
  List<Map<String, dynamic>> _autocompleteResults = [];
  Map<String, dynamic>? _selectedLocation;

  late PlacesService _placesService;

  bool _useDistanceMode = true;
  bool _metroMode = false;
  double _distanceSliderValue = 5.0;
  double _timeSliderValue = 15.0;
  double _stopsSliderValue = 2.0;
  bool _isLoading = false;
  bool _isTracking = false;
  bool _noConnectivity = false;
  bool _lowBattery = false;
  // Use singleton OfflineCoordinator for shared access with TrackingService reroute logic
  OfflineCoordinator get _offline => OfflineCoordinator.instance;

  LatLng? _currentPosition;
  DateTime? _lastPositionTime; // Track when position was last updated
  final Completer<GoogleMapController> _mapController = Completer();
  Set<Marker> _markers = {};
  // Tap handling state for single vs double tap on map
  Timer? _tapTimer;
  DateTime? _lastTapAt;
  LatLng? _lastTapLatLng;
  double _lastZoom = 12.0;

  // Battery instance
  final Battery _battery = Battery();

  // Subscription for connectivity changes remains
  late StreamSubscription<List<ConnectivityResult>> _connectivitySubscription;

  @override
  void initState() {
    super.initState();
    _placesService = PlacesService();
    _loadRecentLocations();
    _initBatteryMonitoring();
    _consumeWidgetArm();
    // OfflineCoordinator.instance is now used via getter, no need to initialize here

    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((
      results,
    ) {
      if (!mounted) return;
      setState(() {
        // Some platforms can report multiple interfaces; treat as offline only
        // when ALL reported states are `none`.
        _noConnectivity =
            results.isEmpty ||
            results.every((r) => r == ConnectivityResult.none);
      });
      _offline.setOffline(_noConnectivity);
      // Inform tracking service about connectivity for reroute gating
      try {
        TrackingService().setOnline(!_noConnectivity);
      } catch (_) {}
    });

    _getCurrentLocation().then((pos) async {
      if (!mounted) return;
      if (pos != null) {
        setState(() {
          _currentPosition = LatLng(pos.latitude, pos.longitude);
          _lastPositionTime = DateTime.now(); // Cache position time
          _markers = {
            Marker(
              markerId: const MarkerId('currentLocation'),
              position: _currentPosition!,
              infoWindow: const InfoWindow(title: 'Current Location'),
            ),
          };
        });
        await _getCountryCode();
      }
    });

    _searchFocus.addListener(() {
      if (!mounted) return;
      if (_searchFocus.hasFocus && _searchController.text.isEmpty) {
        _showTopRecentLocations();
      } else if (!_searchFocus.hasFocus) {
        setState(() => _autocompleteResults = []);
      }
    });
  }

  Future<void> _setDestinationFromLatLng(LatLng position) async {
    final lat = position.latitude;
    final lng = position.longitude;

    // UX: set destination immediately so taps feel responsive even if
    // reverse-geocoding (server call) is slow or offline.
    await _setSelectedLocation('Dropped pin', lat, lng);

    try {
      final result = await ApiClient.instance.geocode(latlng: '$lat,$lng');
      final desc =
          (result != null
              ? (result['formatted_address'] ?? result['name'])
              : null) ??
          'Dropped pin';

      if (!mounted) return;

      // Only update label if the user hasn't already selected a different
      // destination since this request started.
      final selected = _selectedLocation;
      if (selected != null &&
          selected['lat'] == lat &&
          selected['lng'] == lng) {
        await _setSelectedLocation(desc, lat, lng);
      }
    } catch (e) {
      dev.log('Reverse geocode failed on map tap: $e', name: 'HomeScreen');
      // Keep the existing "Dropped pin" selection.
    }
  }

  Future<void> _handleMapTap(LatLng position) async {
    final now = DateTime.now();
    final isQuickSecondTap =
        _lastTapAt != null && now.difference(_lastTapAt!).inMilliseconds < 300;
    final isNearPrevious =
        _lastTapLatLng != null &&
        Geolocator.distanceBetween(
              _lastTapLatLng!.latitude,
              _lastTapLatLng!.longitude,
              position.latitude,
              position.longitude,
            ) <
            40; // within ~40 meters counts as same spot for double-tap

    _lastTapAt = now;
    _lastTapLatLng = position;

    // If this looks like a double-tap: zoom in and cancel pending single-tap action
    if (isQuickSecondTap && isNearPrevious) {
      _tapTimer?.cancel();
      if (_mapController.isCompleted) {
        final controller = await _mapController.future;
        final targetZoom = (_lastZoom.isFinite ? _lastZoom : 12.0) + 1.0;
        controller.animateCamera(
          CameraUpdate.newLatLngZoom(position, targetZoom),
        );
      }
      return;
    }

    // Debounce single-tap to allow time to detect a potential double-tap
    _tapTimer?.cancel();
    _tapTimer = Timer(const Duration(milliseconds: 280), () async {
      await _setDestinationFromLatLng(position);
    });
  }

  Future<void> _initBatteryMonitoring() async {
    final int initialLevel = await _battery.batteryLevel;
    if (!mounted) return;
    setState(() => _lowBattery = (initialLevel < 25));
    _battery.onBatteryStateChanged.listen((state) async {
      final level = await _battery.batteryLevel;
      if (!mounted) return;
      setState(() => _lowBattery = (level < 25));
    });
  }

  Future<void> _getCountryCode() async {
    if (_currentPosition == null) return;
    try {
      final result = await ApiClient.instance.geocode(
        latlng: '${_currentPosition!.latitude},${_currentPosition!.longitude}',
      );
      if (result != null) {
        final components = (result['address_components'] as List?) ?? [];
        final countryComponent = components
            .cast<Map<String, dynamic>?>()
            .firstWhere(
              (c) =>
                  c != null &&
                  ((c['types'] as List?) ?? []).contains('country'),
              orElse: () => null,
            );
        if (countryComponent != null && mounted) {
          setState(() => _currentCountryCode = countryComponent['short_name']);
        }
      }
    } catch (e) {
      dev.log("Error fetching country code via server: $e", name: "HomeScreen");
    }
  }

  /// Extracts the administrative area (state/province) from a geocode result.
  /// Returns null if not found.
  String? _extractStateFromGeocode(Map<String, dynamic>? geocodeResult) {
    if (geocodeResult == null) return null;
    try {
      final components =
          (geocodeResult['address_components'] as List?) ?? const [];
      final stateComponent = components
          .cast<Map<String, dynamic>?>()
          .firstWhere(
            (c) =>
                c != null &&
                ((c['types'] as List?) ?? []).contains(
                  'administrative_area_level_1',
                ),
            orElse: () => null,
          );
      return stateComponent?['short_name'] as String?;
    } catch (e) {
      dev.log('Error extracting state from geocode: $e', name: 'HomeScreen');
      return null;
    }
  }

  /// Validates that origin and destination are in the same state.
  /// Returns true if validation passes, false otherwise.
  Future<bool> _validateSameState({
    required double originLat,
    required double originLng,
    required double destLat,
    required double destLng,
  }) async {
    try {
      // Reverse geocode both origin and destination in parallel
      final originGeocode = ApiClient.instance.geocode(
        latlng: '$originLat,$originLng',
      );
      final destGeocode = ApiClient.instance.geocode(
        latlng: '$destLat,$destLng',
      );

      final results = await Future.wait([originGeocode, destGeocode]);
      final originState = _extractStateFromGeocode(results[0]);
      final destState = _extractStateFromGeocode(results[1]);

      dev.log(
        'Same-state validation: origin=$originState, dest=$destState',
        name: 'HomeScreen',
      );

      // If either state couldn't be determined, allow the route (fail-open)
      if (originState == null || destState == null) {
        dev.log(
          'Same-state validation: skipping (could not determine states)',
          name: 'HomeScreen',
        );
        return true;
      }

      // Check if states match (case-insensitive)
      if (originState.toLowerCase() != destState.toLowerCase()) {
        dev.log(
          'Same-state validation FAILED: different states',
          name: 'HomeScreen',
        );
        return false;
      }

      return true;
    } catch (e) {
      dev.log(
        'Same-state validation error (allowing route): $e',
        name: 'HomeScreen',
      );
      // Fail-open: if validation fails, allow the route
      return true;
    }
  }

  Future<void> _loadRecentLocations() async {
    final loaded = await RecentLocationsService.getRecentLocations();
    if (mounted) {
      setState(
        () => _recentLocations = List<Map<String, dynamic>>.from(loaded),
      );
    }
  }

  void _showTopRecentLocations() {
    final top3 = _recentLocations.take(3).toList();
    setState(() {
      _autocompleteResults =
          top3.map((loc) => {...loc, 'isLocal': true}).toList();
    });
  }

  void _onSearchChanged(String query) {
    if (_debounce?.isActive ?? false) _debounce!.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), () async {
      if (query.isEmpty) {
        if (mounted) _showTopRecentLocations();
        return;
      }

      final localMatches =
          _recentLocations
              .where((loc) {
                return (loc['description'] ?? '').toLowerCase().contains(
                  query.toLowerCase(),
                );
              })
              .map((loc) => {...loc, 'isLocal': true})
              .toList();

      try {
        final remoteResults = await _placesService.fetchAutocompleteResults(
          query,
          countryCode: _currentCountryCode,
          lat: _currentPosition?.latitude,
          lng: _currentPosition?.longitude,
        );

        final combined = [...localMatches];
        for (var remote in remoteResults) {
          if (!combined.any(
            (local) => local['place_id'] == remote['place_id'],
          )) {
            combined.add(remote);
          }
        }

        if (mounted) setState(() => _autocompleteResults = combined);
      } catch (e) {
        dev.log("Error fetching autocomplete results: $e", name: "HomeScreen");
      }
    });
  }

  // =======================================================================
  // CORRECTED LOGIC FOR SELECTING AND SAVING A LOCATION
  // =======================================================================
  Future<void> _onSuggestionSelected(Map<String, dynamic> suggestion) async {
    setState(() => _autocompleteResults = []);
    _searchFocus.unfocus();

    final placeId = suggestion['place_id'];
    if (placeId == null) {
      dev.log("Error: Suggestion is missing a place_id.", name: "HomeScreen");
      return;
    }

    try {
      final details = await _placesService.fetchPlaceDetails(placeId);
      if (details != null) {
        final desc = details['description'] ?? 'Unknown Location';
        final lat = details['lat'];
        final lng = details['lng'];

        // Update the map and selected location state
        await _setSelectedLocation(desc, lat, lng);

        // Correctly save the location with its unique place_id
        await _addToRecentLocations(desc, placeId, lat, lng);
      }
    } catch (e) {
      dev.log("Error fetching place details: $e", name: "HomeScreen");
    }
  }

  Future<void> _setSelectedLocation(String desc, double lat, double lng) async {
    setState(() {
      _selectedLocation = {'description': desc, 'lat': lat, 'lng': lng};
      _searchController.text = desc;
      _markers = {
        Marker(
          markerId: const MarkerId('selectedMarker'),
          position: LatLng(lat, lng),
          infoWindow: InfoWindow(title: desc),
          draggable: true,
          onDragEnd: (newPos) {
            setState(() {
              _selectedLocation?['lat'] = newPos.latitude;
              _selectedLocation?['lng'] = newPos.longitude;
            });
          },
        ),
      };
    });
    final controller = await _mapController.future;
    controller.animateCamera(CameraUpdate.newLatLngZoom(LatLng(lat, lng), 14));
  }

  // =======================================================================
  // CORRECTED LOGIC FOR SAVING RECENTS USING UNIQUE 'place_id'
  // =======================================================================
  Future<void> _addToRecentLocations(
    String desc,
    String placeId,
    double lat,
    double lng,
  ) async {
    // 1. Remove any existing entry with the same UNIQUE place_id.
    _recentLocations.removeWhere((loc) => loc['place_id'] == placeId);

    // 2. Add the new location data to the top of the list.
    _recentLocations.insert(0, {
      'description': desc,
      'place_id': placeId, // Store the unique ID
      'lat': lat,
      'lng': lng,
    });

    // 3. Keep the list from getting too long.
    if (_recentLocations.length > 10) {
      _recentLocations = _recentLocations.sublist(0, 10);
    }

    // 4. Save the updated list to device storage.
    await RecentLocationsService.saveRecentLocations(_recentLocations);
  }

  Future<void> _removeRecentLocation(Map<String, dynamic> suggestion) async {
    setState(() {
      _recentLocations.removeWhere(
        (loc) => loc['place_id'] == suggestion['place_id'],
      );
      _autocompleteResults.removeWhere(
        (item) => item['place_id'] == suggestion['place_id'],
      );
    });
    await RecentLocationsService.saveRecentLocations(_recentLocations);
  }

  // =======================================================================
  // ROUTE MEMORY — automatic recents + frequent trips (no manual saving).
  // GeoWake is position-dependent, so we LEARN routes from behaviour instead of
  // pinning fixed Home/Work destinations. The on-screen "Recent trips" row was
  // removed (the search autocomplete already surfaces recent destinations); the
  // store is still recorded here because the home-screen WIDGET reads it.
  // =======================================================================

  /// Drain a pending widget "arm" tap. The home-screen widget stashes a
  /// RouteMemory id then LAUNCHes the app; on init we consume that id and re-arm
  /// the remembered trip through the normal one-tap flow. Runs on init only —
  /// never on the arm→track→alarm fire path. Fail-safe: a no-op while tracking
  /// or on any error, so a stale tap can never half-arm.
  Future<void> _consumeWidgetArm() async {
    try {
      final routeId = await WidgetArmHandler.instance.consumePendingArm();
      if (routeId == null || !mounted || _isTracking) return;
      final routes = await RouteMemoryService.list();
      RouteMemory? match;
      for (final r in routes) {
        if (r.id == routeId) {
          match = r;
          break;
        }
      }
      if (match == null || !mounted) return;
      await _armFromRoute(match);
    } catch (e) {
      dev.log('widget arm consume ignored: $e', name: 'HomeScreen');
    }
  }

  /// Pre-fill destination + alarm mode/value from a remembered route, then run
  /// the normal Wake-Me flow. Guarded off the fire path; no-op while tracking.
  Future<void> _armFromRoute(RouteMemory r) async {
    if (_isTracking) return;
    setState(() {
      _metroMode = r.metroMode;
      switch (r.alarmMode) {
        case 'stops':
          _useDistanceMode = true;
          _metroMode = true;
          _stopsSliderValue = r.alarmValue.clamp(1.0, 10.0);
          break;
        case 'distance':
          _useDistanceMode = true;
          _metroMode = false;
          _distanceSliderValue = r.alarmValue.clamp(0.5, 10.0);
          break;
        case 'time':
        default:
          _useDistanceMode = false;
          _timeSliderValue = r.alarmValue.clamp(1.0, 60.0);
          break;
      }
    });
    await _setSelectedLocation(r.destinationName, r.lat, r.lng);
    if (r.placeId != null && r.placeId!.isNotEmpty) {
      _selectedLocation!['place_id'] = r.placeId;
    }
    await _onWakeMePressed();
  }

  /// Silently record the just-armed trip into route memory (upsert by coarse
  /// signature; bumps the frequency counter). Origin is captured so a future
  /// re-arm from the same spot can reuse a cached route instead of calling the
  /// Directions API. Never throws into the arming path.
  Future<void> _recordRouteMemory({
    required String destinationName,
    required double destLat,
    required double destLng,
    required String alarmMode,
    required double alarmValue,
    required bool metroMode,
    String? metroLine,
    double? originLat,
    double? originLng,
    String? placeId,
  }) async {
    try {
      await RouteMemoryService.record(
        destinationName: destinationName,
        lat: destLat,
        lng: destLng,
        placeId: placeId,
        alarmMode: alarmMode,
        alarmValue: alarmValue,
        metroMode: metroMode,
        metroLine: metroLine,
        originLat: originLat,
        originLng: originLng,
      );
    } catch (e) {
      dev.log('Failed to record route memory: $e', name: 'HomeScreen');
    }
  }

  /// G24: surface a plain-spoken reliability/safety disclaimer exactly once.
  /// On some phones (aggressive battery managers, Do-Not-Disturb, very deep
  /// sleep) the wake-up alarm may not fire, so riders should keep a backup
  /// alarm. Persists a "shown" flag in shared_preferences so it never nags.
  Future<void> _maybeShowReliabilityDisclaimer() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('reliability_disclaimer_shown') == true) return;
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder:
            (ctx) => AlertDialog(
              title: const Text('Please keep a backup alarm'),
              content: const Text(
                'GeoWake does its best to wake you at your stop, but no phone app '
                'can guarantee it. On some phones, aggressive battery savers, Do Not '
                'Disturb, or very deep sleep can delay or silence the alarm.\n\n'
                'For any trip you truly can\'t miss, please also set a backup alarm.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Got it'),
                ),
              ],
            ),
      );
      await prefs.setBool('reliability_disclaimer_shown', true);
    } catch (_) {
      // Never block arming a session on the disclaimer.
    }
  }

  Future<void> _onWakeMePressed() async {
    final stopwatch = Stopwatch()..start();
    dev.log(
      '[StartupPerf] WakeMe Pressed: ${stopwatch.elapsedMilliseconds}ms',
      name: 'Performance',
    );

    if (_selectedLocation == null) {
      _showErrorDialog(
        "Destination Missing",
        "Please select a valid destination.",
      );
      return;
    }
    setState(() {
      _isLoading = true;
    });

    // This is the updated block that uses our new, robust service
    final permissionService = PermissionService(context);
    final bool canProceed =
        await permissionService.requestEssentialPermissions();
    dev.log(
      '[StartupPerf] Permissions Checked: ${stopwatch.elapsedMilliseconds}ms',
      name: 'Performance',
    );

    if (!mounted) return;

    if (canProceed) {
      // G24: honest, one-time reliability disclaimer before the first armed
      // session. Non-blocking beyond a single "Got it" dismissal.
      await _maybeShowReliabilityDisclaimer();
      if (!mounted) return;
      // Permissions were granted, proceed with tracking!
      setState(() => _isTracking = true);
      await _proceedWithDirections(stopwatch);
    } else {
      // Permissions were denied. The service already showed the user a dialog.
      // We just need to reset the loading state.
      setState(() => _isLoading = false);
    }
  }

  Future<void> _proceedWithDirections(Stopwatch stopwatch) async {
    try {
      dev.log(
        '[StartupPerf] Proceed Directions Start: ${stopwatch.elapsedMilliseconds}ms',
        name: 'Performance',
      );

      // OPTIMIZATION: Use cached position if fresh (< 30 seconds old), else get new one
      Position? currentPosition;
      if (_currentPosition != null && _lastPositionTime != null) {
        final age = DateTime.now().difference(_lastPositionTime!);
        if (age.inSeconds < 30) {
          currentPosition = Position(
            latitude: _currentPosition!.latitude,
            longitude: _currentPosition!.longitude,
            timestamp: _lastPositionTime!,
            accuracy: 10,
            altitude: 0,
            altitudeAccuracy: 0,
            heading: 0,
            headingAccuracy: 0,
            speed: 0,
            speedAccuracy: 0,
          );
          dev.log(
            'Using cached position (${age.inSeconds}s old)',
            name: 'HomeScreen',
          );
        }
      }
      currentPosition ??= await _getCurrentLocation();
      dev.log(
        '[StartupPerf] Location Acquired: ${stopwatch.elapsedMilliseconds}ms',
        name: 'Performance',
      );

      if (currentPosition == null) {
        _showErrorDialog(
          "Location Error",
          "Could not get your current location. Please enable location services.",
        );
        setState(() {
          _isTracking = false;
          _isLoading = false;
        });
        return;
      }

      double destLat = _selectedLocation!['lat'];
      double destLng = _selectedLocation!['lng'];
      double userLat = currentPosition.latitude;
      double userLng = currentPosition.longitude;

      // OPTIMIZATION: Run validations in parallel with directions fetch
      // Start same-state validation early (fire-and-forget, check result later)
      final sameStateFuture = _validateSameState(
        originLat: userLat,
        originLng: userLng,
        destLat: destLat,
        destLng: destLng,
      );

      if (_metroMode) {
        final validationResult = await MetroStopService.validateMetroRoute(
          startLocation: LatLng(userLat, userLng),
          destination: LatLng(destLat, destLng),
        );
        dev.log(
          '[StartupPerf] Metro Validation: ${stopwatch.elapsedMilliseconds}ms',
          name: 'Performance',
        );

        if (!mounted) return;
        if (!validationResult.isValid || validationResult.closestStop == null) {
          _showErrorDialog(
            "Metro Route Unavailable",
            validationResult.errorMessage ?? "No valid metro route found.",
          );
          setState(() {
            _isTracking = false;
            _isLoading = false;
          });
          return;
        } else {
          destLat = validationResult.closestStop!.location.latitude;
          destLng = validationResult.closestStop!.location.longitude;
        }
      }

      // Start fetching directions while same-state validation completes
      final directionsFuture = _fetchDirections(
        userLat,
        userLng,
        destLat,
        destLng,
      );

      // Now wait for same-state validation result
      final sameState = await sameStateFuture;
      dev.log(
        '[StartupPerf] State Validation: ${stopwatch.elapsedMilliseconds}ms',
        name: 'Performance',
      );

      if (!mounted) return;
      // GAP #5 (BLOCK, fixed): cross-state routes were HARD-BLOCKED here,
      // refusing the flagship overnight interstate sleeper (Delhi->Jaipur,
      // Mumbai->Ahmedabad) — the exact "sleep through it, wake me before my
      // stop" trip GeoWake exists for. A transit wake-alarm must NEVER refuse a
      // long-distance journey. The reverse-geocode result is retained only as a
      // soft signal (logged); it no longer blocks arming.
      if (!sameState) {
        dev.log(
          'Cross-state route detected — arming anyway. Interstate journeys are '
          'supported (flagship overnight use case); no hard block.',
          name: 'HomeScreen',
        );
      }

      final directions = await directionsFuture;
      dev.log(
        '[StartupPerf] API Directions Fetched: ${stopwatch.elapsedMilliseconds}ms',
        name: 'Performance',
      );

      final initialETA =
          directions['routes'][0]['legs'][0]['duration']['value'] as int;

      // G18: The flagship use case is a 6-10h single-stop sleeper journey, so
      // long journeys are intentionally NOT capped. We only refuse plainly
      // invalid (>24h) total durations, which indicate corrupt/looping route
      // data rather than a real trip. Computed across ALL legs so a multi-leg
      // journey isn't under-measured by leg 0 alone.
      final totalPlannedSeconds = TransferUtils.totalPlannedDurationSeconds(
        directions,
      );
      const int maxSaneJourneySeconds =
          24 * 3600; // 86400s ceiling, ~2.4x max sleeper
      if (totalPlannedSeconds > maxSaneJourneySeconds) {
        _showErrorDialog(
          "Route Too Long",
          "This route appears longer than 24 hours, which usually means the route data is invalid. Please re-select your destination.",
        );
        setState(() {
          _isTracking = false;
          _isLoading = false;
        });
        return;
      }

      final trackingService = TrackingService();

      // Compute alarm mode/value. For metro+stops, use stops-based threshold.
      String alarmMode = _useDistanceMode ? 'distance' : 'time';
      double alarmValue;
      if (_metroMode && _useDistanceMode) {
        // When metro mode and 'stops' selected, send stops threshold directly
        alarmMode = 'stops';
        alarmValue = _stopsSliderValue;
      } else {
        alarmValue = _useDistanceMode ? _distanceSliderValue : _timeSliderValue;
      }

      // Stops-mode validation
      if (alarmMode == 'stops') {
        debugPrint(
          '[StopsValidation] begin: threshold=$alarmValue metroMode=$_metroMode',
        );
        // When in metro mode, only count metro stops (ignore bus stops)
        // This ensures threshold validation uses the correct stop counts
        final stepData = TransferUtils.buildStepBoundariesAndStops(
          directions,
          metroOnly: _metroMode,
        );
        final events = TransferUtils.buildRouteEvents(directions);

        // Add destination event if missing (TransferUtils might miss it if single leg)
        if (events.isEmpty || events.last.type != 'destination') {
          final lastBound =
              stepData.bounds.isNotEmpty ? stepData.bounds.last : 0.0;
          events.add(
            RouteEventBoundary(
              meters: lastBound,
              type: 'destination',
              label: 'Destination',
            ),
          );
        }

        debugPrint(
          '[StopsValidation] events=${events.length} stepBounds=${stepData.bounds.length} totalStops=${stepData.stops.isNotEmpty ? stepData.stops.last : 0}',
        );

        dev.log(
          '[StartupPerf] Stops & Events Built: ${stopwatch.elapsedMilliseconds}ms',
          name: 'Performance',
        );

        final engine = StopLogicEngine();
        final result = engine.validateThreshold(
          userThreshold: alarmValue,
          stepBoundsMeters: stepData.bounds,
          stepStopsCumulative: stepData.stops,
          routeEvents: events,
        );

        dev.log(
          '[StartupPerf] Stop Logic Validated: ${stopwatch.elapsedMilliseconds}ms',
          name: 'Performance',
        );

        if (!result.isValid) {
          debugPrint(
            '[StopsValidation] FAIL first-segment: threshold=$alarmValue maxStops=${result.maxStops} bounds=${stepData.bounds.length} stops=${stepData.stops.length} events=${events.length}',
          );
          dev.log(
            'Stops-mode validation failed: threshold=$alarmValue, maxStops=${result.maxStops}, bounds=${stepData.bounds.length}, stops=${stepData.stops.length}, events=${events.length}',
            name: 'StopLogicEngine',
          );
          if (events.isNotEmpty) {
            final first = events.first;
            dev.log(
              'First event: type=${first.type}, meters=${first.meters.toStringAsFixed(0)}, label=${first.label}',
              name: 'StopLogicEngine',
            );
          }
          _showErrorDialog(
            "Invalid Stops Threshold",
            result.errorMessage ??
                "The number of stops ($alarmValue) is too high for the first segment of your journey. Max allowed is ${result.maxStops}.",
          );
          if (mounted) {
            setState(() {
              _isTracking = false;
              _isLoading = false;
            });
          }
          return;
        }

        // NEW: Validate threshold against minimum stops on any metro leg
        // Rule: User cannot choose n >= min(stops across all metro legs)
        final transitLegs = TransferUtils.extractTransitLegStops(directions);
        dev.log(
          'Stops-mode legs extracted: count=${transitLegs.length}',
          name: 'StopLogicEngine',
        );
        for (final leg in transitLegs) {
          dev.log(
            'Leg: name=${leg.lineName}, isMetro=${leg.isMetro}, numStops=${leg.numStops}, totalStops=${leg.numStops + 1}, start=${leg.legStartMeters.toStringAsFixed(0)}, end=${leg.legEndMeters.toStringAsFixed(0)}',
            name: 'StopLogicEngine',
          );
        }
        final metroLegResult = engine.validateThresholdAgainstMetroLegs(
          userThreshold: alarmValue.toInt(),
          transitLegs: transitLegs,
        );

        if (!metroLegResult.isValid) {
          debugPrint(
            '[StopsValidation] FAIL metro-leg: threshold=$alarmValue minMetroStops=${metroLegResult.minMetroStops} legs=${transitLegs.length}',
          );
          final metroCount = transitLegs.where((leg) => leg.isMetro).length;
          final nonMetroCount = transitLegs.length - metroCount;
          dev.log(
            'Metro-leg validation failed: threshold=$alarmValue, metroCount=$metroCount, nonMetroCount=$nonMetroCount, minMetroStops=${metroLegResult.minMetroStops}',
            name: 'StopLogicEngine',
          );
          _showErrorDialog(
            "Invalid Stops Threshold",
            metroLegResult.errorMessage ??
                "The number of stops ($alarmValue) exceeds the minimum stops available on a metro segment.",
          );
          if (mounted) {
            setState(() {
              _isTracking = false;
              _isLoading = false;
            });
          }
          return;
        }

        dev.log(
          '[StartupPerf] Metro Leg Validation Passed: min=${metroLegResult.minMetroStops}',
          name: 'Performance',
        );
      }

      // Pre-arm confirmation: resolve the abstract alarm setting into concrete
      // terms so the rider trusts it enough to actually sleep. Dismissible.
      if (!mounted) return;
      setState(() {
        _isLoading = false; // Clear spinner so the sheet is presented cleanly.
      });
      final confirmed = await _showPreArmConfirmation(
        destinationName:
            _selectedLocation?['description'] ?? 'your destination',
        alarmMode: alarmMode,
        alarmValue: alarmValue,
        totalEtaSeconds: totalPlannedSeconds,
        directions: directions,
      );
      if (!mounted) return;
      if (confirmed != true) {
        // Rider backed out — abort arming, leave them on the home screen.
        setState(() {
          _isTracking = false;
          _isLoading = false;
        });
        return;
      }
      setState(() {
        _isLoading = true; // Re-show spinner while tracking spins up.
      });

      // 1. Start Tracking (Ensure service is running)
      // Parallelize state persistence for faster startup
      try {
        await Future.wait([
          TrackingStateStore.setActive(true),
          TrackingStateStore.setAlarmFired(false),
          TrackingStateStore.setNotificationsMuted(false),
        ]);
        dev.log(
          '[StartupPerf] Simple State Saved: ${stopwatch.elapsedMilliseconds}ms',
          name: 'Performance',
        );

        await TrackingStateStore.saveSnapshot(
          TrackingSnapshot(
            destinationName:
                _selectedLocation?['description'] ?? 'Your Destination',
            destinationLat: destLat,
            destinationLng: destLng,
            alarmMode: alarmMode,
            alarmValue: alarmValue,
            metroMode: _metroMode,
            userLat: userLat,
            userLng: userLng,
            createdAt: DateTime.now(),
            directions: directions, // Save directions for app restore
          ),
        );
        dev.log(
          '[StartupPerf] Heavy Snapshot Saved: ${stopwatch.elapsedMilliseconds}ms',
          name: 'Performance',
        );
      } catch (e) {
        dev.log('Failed to persist tracking snapshot: $e', name: 'HomeScreen');
      }

      // HANDOFF §1 P1.3 + GAP #4: pre-trip reliability preflight. Before the
      // rider trusts the alarm for a real commute, check whether the OS could
      // stop it from waking them. A `warn`-level issue (no exact-alarm, battery
      // optimisation on an aggressive OEM) is advisory and arming proceeds. A
      // `block`-level issue (notifications disabled → the wake can physically
      // never appear) HONESTLY REFUSES to arm — GeoWake must guarantee a fireable
      // channel or decline, never silently arm a dead one. This is not gating the
      // core alarm behind setup (reliability is never sold); it is refusing to
      // make a promise the OS won't let us keep. Fail-open: any *error* running
      // the preflight proceeds (the check must never crash the arm flow).
      try {
        final preflight = await ReliabilityPreflightRunner.run();
        if (!preflight.isOk && mounted) {
          final proceed = await showReliabilityPreflightDialog(
            context,
            preflight,
          );
          if (!proceed) {
            if (mounted) {
              setState(() {
                _isTracking = false;
                _isLoading = false;
              });
            }
            return; // blocking channel issue — do not arm a dead delivery path
          }
        }
      } catch (_) {
        /* a preflight ERROR must never crash the arm flow */
      }

      await trackingService.startTracking(
        destination: LatLng(destLat, destLng),
        destinationName:
            _selectedLocation?['description'] ?? 'Your Destination',
        alarmMode: alarmMode,
        alarmValue: alarmValue,
        transitMode: _metroMode,
      );
      dev.log(
        '[StartupPerf] Tracking Service Started: ${stopwatch.elapsedMilliseconds}ms',
        name: 'Performance',
      );

      // Guardian mode (Pro): auto-share this commute with the saved contact so
      // they can follow the live ride. Fire-and-forget and self-gating — it
      // no-ops unless the user is Pro + enabled Guardian + set a contact, and it
      // runs ONLY AFTER startTracking() has already returned, so it can never
      // delay, reorder, or fail the arm→track→alarm spine. It starts a
      // JourneyShare (reusing JourneyShareService) and composes the tracking link
      // into the user's SMS/WhatsApp app for them to send. Never throws.
      unawaited(
        GuardianService.instance.onJourneyArmed(
          destLabel: _selectedLocation?['description'] ?? 'Your Destination',
          eta: DateTime.now().add(Duration(seconds: initialETA)),
        ),
      );

      // Remember this trip (recents + frequency). Fire-and-forget — must never
      // block or fail the arming flow. Origin lets a later re-arm reuse cache.
      unawaited(
        _recordRouteMemory(
          destinationName:
              _selectedLocation?['description'] ?? 'Your Destination',
          destLat: destLat,
          destLng: destLng,
          alarmMode: alarmMode,
          alarmValue: alarmValue,
          metroMode: _metroMode,
          originLat: userLat,
          originLng: userLng,
          placeId: _selectedLocation?['place_id'] as String?,
        ),
      );

      // 2. Register Route (fire-and-forget for faster navigation)
      // The background service will receive route events asynchronously.
      // MapTrackingScreen will still display correctly as directions are passed via args.
      unawaited(
        trackingService
            .registerRouteFromDirections(
              directions: directions,
              origin: LatLng(userLat, userLng),
              destination: LatLng(destLat, destLng),
              transitMode: _metroMode,
              destinationName:
                  _selectedLocation?['description'] ?? 'Your Destination',
              activateRoute:
                  true, // Ensure RouteSessionManager updates active key & triggers migration
            )
            .catchError((e) {
              dev.log(
                'Failed to register route with TrackingService: $e',
                name: 'HomeScreen',
              );
            }),
      );

      FlutterBackgroundService().invoke("updateRouteData", {
        "initialETA": initialETA,
      });

      final Map<String, dynamic> mapArgs = {
        'destination': _searchController.text,
        'mode':
            _metroMode && _useDistanceMode
                ? 'stops'
                : (_useDistanceMode ? 'distance' : 'time'),
        'value':
            _metroMode && _useDistanceMode
                ? _stopsSliderValue
                : (_useDistanceMode ? _distanceSliderValue : _timeSliderValue),
        'metroMode': _metroMode,
        'directions': directions,
        'userLat': userLat,
        'userLng': userLng,
        'lat': destLat,
        'lng': destLng,
      };

      dev.log(
        '[StartupPerf] Start Navigation: ${stopwatch.elapsedMilliseconds}ms',
        name: 'Performance',
      );

      if (!context.mounted) return;
      Navigator.pushReplacementNamed(
        context,
        '/preloadMap',
        arguments: mapArgs,
      );
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    } catch (e) {
      dev.log("Error in _proceedWithDirections: $e", name: "HomeScreen");
      if (mounted) {
        _showErrorDialog(
          "Route Error",
          "Could not calculate the route. Please try again.",
        );
        setState(() {
          _isTracking = false;
          _isLoading = false;
        });
      }
    }
  }

  /// Human-readable short ETA (e.g. "45 min", "2.5 hr").
  String _formatEtaShort(num seconds) {
    final s = seconds.toDouble();
    if (!s.isFinite || s <= 0) return 'a moment';
    if (s < 90) return '${s.round()} sec';
    if (s < 3600) return '${(s / 60).round()} min';
    final h = s / 3600.0;
    return h < 10 ? '${h.toStringAsFixed(1)} hr' : '${h.round()} hr';
  }

  /// Trim a double for display: drop the decimal when it's a whole number.
  String _trimNum(double v) =>
      v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);

  /// Best-effort name of the last transit alighting stop, for stops-mode copy.
  /// Falls back to null so the caller can substitute the destination name.
  String? _lastAlightingStopName(Map<String, dynamic> directions) {
    try {
      final routes = directions['routes'] as List?;
      if (routes == null || routes.isEmpty) return null;
      final legs = (routes.first as Map)['legs'] as List?;
      String? name;
      for (final leg in legs ?? const []) {
        final steps = (leg as Map)['steps'] as List? ?? const [];
        for (final step in steps) {
          final td = (step as Map)['transit_details'] as Map?;
          final arr = td?['arrival_stop'] as Map?;
          final n = arr?['name'] as String?;
          if (n != null && n.trim().isNotEmpty) name = n.trim();
        }
      }
      return name;
    } catch (_) {
      return null;
    }
  }

  /// Show a short, dismissible confirmation sheet that resolves the abstract
  /// alarm setting into concrete terms before we start tracking. Returns true
  /// only if the rider explicitly confirms.
  Future<bool?> _showPreArmConfirmation({
    required String destinationName,
    required String alarmMode,
    required double alarmValue,
    required num totalEtaSeconds,
    required Map<String, dynamic> directions,
  }) async {
    final etaStr = _formatEtaShort(totalEtaSeconds);

    String wakeLine;
    switch (alarmMode) {
      case 'stops':
        final n = alarmValue.round();
        final stop = _lastAlightingStopName(directions) ?? destinationName;
        wakeLine = "We'll wake you $n stop${n == 1 ? '' : 's'} before $stop.";
        break;
      case 'distance':
        wakeLine =
            "We'll wake you ${_trimNum(alarmValue)} km before $destinationName.";
        break;
      case 'time':
      default:
        wakeLine =
            "We'll wake you ${alarmValue.round()} min before $destinationName.";
    }

    return showModalBottomSheet<bool>(
      context: context,
      isDismissible: true,
      isScrollControlled: false,
      showDragHandle: true,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(Icons.bedtime, color: cs.primary, size: 28),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        'Ready to sleep?',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Text(
                  'Arriving at $destinationName in ~$etaStr.',
                  style: const TextStyle(fontSize: 15),
                ),
                const SizedBox(height: 8),
                Text(
                  wakeLine,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.of(ctx).pop(false),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        child: const Text('Not yet'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: () => Navigator.of(ctx).pop(true),
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          backgroundColor: cs.primary,
                          foregroundColor: cs.onPrimary,
                        ),
                        icon: const Icon(Icons.notifications_active, size: 20),
                        label: const Text('Wake me'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // Removed legacy km-per-stop estimator (now use stops mode directly)

  void _showErrorDialog(String title, String message) {
    if (!mounted) return;
    debugPrint(
      '[ShowErrorDialog] title="$title" message="$message" mode=${_useDistanceMode ? (_metroMode ? "stops" : "distance") : "time"} threshold=${_useDistanceMode ? (_metroMode ? _stopsSliderValue.toStringAsFixed(0) : _distanceSliderValue.toStringAsFixed(1)) : _timeSliderValue.toStringAsFixed(0)} metroMode=$_metroMode',
    );
    dev.log(
      'ShowErrorDialog: title="$title" message="$message" mode=${_useDistanceMode ? (_metroMode ? "stops" : "distance") : "time"} threshold=${_useDistanceMode ? (_metroMode ? _stopsSliderValue.toStringAsFixed(0) : _distanceSliderValue.toStringAsFixed(1)) : _timeSliderValue.toStringAsFixed(0)} metroMode=$_metroMode',
      name: 'HomeScreen',
    );
    showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: <Widget>[
            TextButton(
              child: const Text('OK'),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        );
      },
    );
  }

  Future<Position?> _getCurrentLocation() async {
    try {
      return await Geolocator.getCurrentPosition();
    } catch (e) {
      return null;
    }
  }

  Future<Map<String, dynamic>> _fetchDirections(
    double startLat,
    double startLng,
    double endLat,
    double endLng,
  ) async {
    final threshold =
        _useDistanceMode
            ? (_metroMode ? _stopsSliderValue : _distanceSliderValue)
            : _timeSliderValue;
    try {
      final res = await _offline.getRoute(
        origin: LatLng(startLat, startLng),
        destination: LatLng(endLat, endLng),
        isDistanceMode: _useDistanceMode,
        threshold: threshold,
        transitMode: _metroMode,
        preferMetroEvenIfClosed: _metroMode,
        forceRefresh: false,
      );
      return res.directions;
    } catch (e) {
      if (_noConnectivity) {
        throw Exception("Offline with no cached route available.");
      }
      throw Exception("Failed to fetch directions: $e");
    }
  }

  // (Reverted) No special blocking for absence of metro in directions

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _searchFocus.dispose();
    _connectivitySubscription.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;
    final bool isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = Theme.of(context).colorScheme;
    final Color searchBarFillColor =
        isDarkMode ? Colors.grey[800]! : Colors.grey[200]!;
    final Color clearSearchIconColor =
        isDarkMode ? colorScheme.onSurface.withOpacity(0.75) : Colors.black54;
    final Color clearChipBg =
        isDarkMode
            ? colorScheme.surfaceContainerHighest.withOpacity(0.45)
            : Colors.grey.shade200;
    final Color clearChipBorder =
        isDarkMode
            ? colorScheme.outline.withOpacity(0.5)
            : Colors.grey.shade300;
    final Color clearChipIconColor =
        isDarkMode
            ? colorScheme.onSurfaceVariant.withOpacity(0.9)
            : Colors.grey.shade700;

    return Scaffold(
      drawer: SettingsDrawer(
        metroModeEnabled: _metroMode,
        isMetroTimeMode: _metroMode && !_useDistanceMode,
      ),
      appBar: AppBar(
        title: Text(
          'GeoWake',
          style: GoogleFonts.pacifico(
            textStyle: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: screenWidth * 0.07,
            ),
          ),
        ),
        actions: [
          Row(
            children: [
              const Text('Metro Mode', style: TextStyle(fontSize: 12)),
              Semantics(
                label: 'Metro mode toggle',
                identifier: 'home_metro_mode_toggle',
                child: Switch(
                  value: _metroMode,
                  onChanged:
                      _isTracking
                          ? null
                          : (val) => setState(() => _metroMode = val),
                ),
              ),
              const SizedBox(width: 8),
            ],
          ),
        ],
      ),
      // Route-arming surface: a real gated banner (free users only, collapses to
      // nothing for Pro / no-fill). Never covers the map or the Wake-Me control.
      bottomNavigationBar: const SafeArea(
        child: GatedBannerAd(placement: AdPlacement.routeArming),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.all(screenWidth * 0.04),
                child: AbsorbPointer(
                  absorbing: _isTracking,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_noConnectivity)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            vertical: 8,
                            horizontal: 12,
                          ),
                          margin: const EdgeInsets.only(bottom: 8),
                          decoration: BoxDecoration(
                            color: Colors.amber.shade700,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            children: const [
                              Icon(Icons.wifi_off, color: Colors.white),
                              SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Offline mode: using cached routes only',
                                  style: TextStyle(color: Colors.white),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ValueListenableBuilder<TextEditingValue>(
                        valueListenable: _searchController,
                        builder: (context, value, _) {
                          final hasText = value.text.isNotEmpty;
                          return TextField(
                            focusNode: _searchFocus,
                            controller: _searchController,
                            onChanged: _onSearchChanged,
                            style: TextStyle(
                              color: isDarkMode ? Colors.white : Colors.black,
                            ),
                            decoration: InputDecoration(
                              hintText: 'Enter your destination',
                              prefixIcon: const Icon(Icons.search),
                              suffixIcon:
                                  hasText
                                      ? IconButton(
                                        tooltip: 'Clear search',
                                        icon: Icon(
                                          Icons.close,
                                          semanticLabel: 'Clear search',
                                          color: clearSearchIconColor,
                                        ),
                                        onPressed: () {
                                          _searchController.clear();
                                          if (mounted)
                                            _showTopRecentLocations();
                                        },
                                      )
                                      : null,
                              contentPadding: EdgeInsets.symmetric(
                                vertical: screenHeight * 0.015,
                                horizontal: screenWidth * 0.04,
                              ),
                              filled: true,
                              fillColor: searchBarFillColor,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(24),
                                borderSide: BorderSide.none,
                              ),
                              hintStyle: TextStyle(
                                color:
                                    isDarkMode
                                        ? Colors.white70
                                        : Colors.black54,
                              ),
                              prefixIconColor:
                                  isDarkMode ? Colors.white70 : Colors.black54,
                            ),
                          );
                        },
                      ),
                      SizedBox(height: screenHeight * 0.01),
                      if (_autocompleteResults.isNotEmpty)
                        Container(
                          decoration: BoxDecoration(
                            color: isDarkMode ? Colors.grey[800] : Colors.white,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: ListView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: _autocompleteResults.length,
                            itemBuilder: (context, index) {
                              final suggestion = _autocompleteResults[index];
                              return ListTile(
                                title: Text(
                                  suggestion['description'] ?? 'Unknown',
                                ),
                                onTap: () => _onSuggestionSelected(suggestion),
                                trailing:
                                    suggestion['isLocal'] == true
                                        ? GestureDetector(
                                          onTap:
                                              () => _removeRecentLocation(
                                                suggestion,
                                              ),
                                          child: Container(
                                            decoration: BoxDecoration(
                                              shape: BoxShape.circle,
                                              color: clearChipBg,
                                              border: Border.all(
                                                color: clearChipBorder,
                                                width: 0.8,
                                              ),
                                            ),
                                            padding: const EdgeInsets.all(4),
                                            child: Icon(
                                              Icons.close,
                                              size: 16,
                                              semanticLabel:
                                                  'Remove recent destination',
                                              color: clearChipIconColor,
                                            ),
                                          ),
                                        )
                                        : null,
                              );
                            },
                          ),
                        ),
                      SizedBox(height: screenHeight * 0.02),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: SizedBox(
                          height: screenHeight * 0.3,
                          child: GoogleMap(
                            initialCameraPosition: CameraPosition(
                              target:
                                  _currentPosition ??
                                  const LatLng(12.9716, 77.5946), // Bengaluru
                              zoom: 12,
                            ),
                            markers: _markers,
                            onTap: _handleMapTap,
                            onCameraMove: (position) {
                              _lastZoom = position.zoom;
                            },
                            onMapCreated: (controller) {
                              if (!_mapController.isCompleted) {
                                _mapController.complete(controller);
                              }
                            },
                          ),
                        ),
                      ),
                      SizedBox(height: screenHeight * 0.03),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Text('Time'),
                          Semantics(
                            label: 'Alarm trigger mode toggle',
                            identifier: 'home_mode_toggle',
                            child: Switch(
                              value: _useDistanceMode,
                              onChanged:
                                  (val) =>
                                      setState(() => _useDistanceMode = val),
                            ),
                          ),
                          Text(_metroMode ? 'Stops' : 'Distance'),
                        ],
                      ),
                      SizedBox(height: screenHeight * 0.02),
                      GestureDetector(
                        onTap: () async {
                          final newValue = await showDialog<double>(
                            context: context,
                            builder: (_) {
                              return _EnterValueDialog(
                                initialValue:
                                    _useDistanceMode
                                        ? (_metroMode
                                            ? _stopsSliderValue
                                            : _distanceSliderValue)
                                        : _timeSliderValue,
                                isDistanceMode: _useDistanceMode && !_metroMode,
                                isStopsMode: _useDistanceMode && _metroMode,
                              );
                            },
                          );
                          if (!mounted) return;
                          if (newValue != null) {
                            setState(() {
                              if (_useDistanceMode) {
                                if (_metroMode) {
                                  _stopsSliderValue = newValue.clamp(1.0, 10.0);
                                } else {
                                  _distanceSliderValue = newValue.clamp(
                                    0.5,
                                    10.0,
                                  );
                                }
                              } else {
                                _timeSliderValue = newValue.clamp(1.0, 60.0);
                              }
                            });
                          }
                        },
                        child: Container(
                          padding: EdgeInsets.symmetric(
                            vertical: screenHeight * 0.015,
                            horizontal: screenWidth * 0.04,
                          ),
                          decoration: BoxDecoration(
                            color:
                                isDarkMode
                                    ? Colors.grey[700]
                                    : Colors.grey[200],
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: isDarkMode ? Colors.white38 : Colors.grey,
                              width: 1.0,
                            ),
                          ),
                          child: Text(
                            _useDistanceMode
                                ? (_metroMode
                                    ? 'Alert me ${_stopsSliderValue.toStringAsFixed(0)} stops prior'
                                    : 'Alert me within ${_distanceSliderValue.toStringAsFixed(1)} km')
                                : 'Alert me in ${_timeSliderValue.toStringAsFixed(0)} min',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: screenWidth * 0.045),
                          ),
                        ),
                      ),
                      SizedBox(height: screenHeight * 0.015),
                      Semantics(
                        label: 'Alarm threshold slider',
                        identifier: 'home_threshold_slider',
                        child: Slider(
                        value:
                            _useDistanceMode
                                ? (_metroMode
                                    ? _stopsSliderValue
                                    : _distanceSliderValue)
                                : _timeSliderValue,
                        min: _useDistanceMode ? (_metroMode ? 1.0 : 0.5) : 1.0,
                        max:
                            _useDistanceMode
                                ? (_metroMode ? 10.0 : 10.0)
                                : 60.0,
                        divisions:
                            _useDistanceMode ? (_metroMode ? 9 : 19) : 59,
                        label:
                            _useDistanceMode
                                ? (_metroMode
                                    ? _stopsSliderValue.toStringAsFixed(0)
                                    : _distanceSliderValue.toStringAsFixed(1))
                                : _timeSliderValue.toStringAsFixed(0),
                        onChanged: (val) {
                          setState(() {
                            if (_useDistanceMode) {
                              if (_metroMode) {
                                // Stops slider should be integer-like in feel
                                _stopsSliderValue = val.round().toDouble();
                              } else {
                                _distanceSliderValue = val;
                              }
                            } else {
                              _timeSliderValue = val;
                            }
                          });
                        },
                        ),
                      ),
                      if (_lowBattery)
                        Padding(
                          padding: EdgeInsets.only(top: screenHeight * 0.02),
                          child: Row(
                            children: [
                              const Spacer(),
                              _buildAlertButton(
                                icon: Icons.battery_alert,
                                onPressed: () {},
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            // Docked primary CTA — the "Wake Me!" action lives in a persistent
            // bottom bar (always thumb-reachable) instead of floating in the
            // scroll body with a gap beneath it. It sits ABOVE the gated ad
            // banner (the Scaffold's bottomNavigationBar), so an ad can never
            // overlap the wake control (AdPolicy invariant).
            _buildWakeMeBar(context, screenWidth, screenHeight),
          ],
        ),
      ),
      // No floating action button in production
    );
  }

  /// The primary "Wake Me!" call-to-action, docked in a persistent bottom bar so
  /// it is always thumb-reachable and no longer floats in the scroll body with a
  /// gap beneath it (which is what showed once the gated ad banner collapsed to
  /// zero on no-fill). It renders ABOVE the ad banner (the Scaffold's
  /// bottomNavigationBar), so an ad can never overlap the wake control.
  Widget _buildWakeMeBar(
    BuildContext context,
    double screenWidth,
    double screenHeight,
  ) {
    final cs = Theme.of(context).colorScheme;
    final bool enabled =
        _selectedLocation != null &&
        _searchController.text.isNotEmpty &&
        !_isLoading &&
        !_isTracking;
    return Container(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.5)),
        ),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          screenWidth * 0.04,
          10,
          screenWidth * 0.04,
          10,
        ),
        child: SizedBox(
          width: double.infinity,
          child: Semantics(
            label: 'Arm wake alarm',
            identifier: 'wake_me_cta',
            button: true,
            child: ElevatedButton(
              onPressed: enabled ? _onWakeMePressed : null,
            child:
                _isLoading
                    ? Row(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              Colors.white,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          'Loading route...',
                          style: TextStyle(fontSize: screenWidth * 0.05),
                        ),
                      ],
                    )
                    : Text(
                      'Wake Me!',
                      style: TextStyle(fontSize: screenWidth * 0.05),
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAlertButton({
    required IconData icon,
    required VoidCallback onPressed,
  }) {
    return Material(
      color: Colors.redAccent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          child: Icon(
            icon,
            color: Colors.white,
            size: 24,
            semanticLabel: 'Low battery warning',
          ),
        ),
      ),
    );
  }
}

class _EnterValueDialog extends StatefulWidget {
  final double initialValue;
  final bool isDistanceMode;
  final bool isStopsMode;
  const _EnterValueDialog({
    required this.initialValue,
    required this.isDistanceMode,
    this.isStopsMode = false,
  });
  @override
  State<_EnterValueDialog> createState() => _EnterValueDialogState();
}

class _EnterValueDialogState extends State<_EnterValueDialog> {
  late TextEditingController _controller;
  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text:
          widget.isDistanceMode
              ? widget.initialValue.toStringAsFixed(1)
              : widget.isStopsMode
              ? widget.initialValue.toStringAsFixed(0)
              : widget.initialValue.toStringAsFixed(0),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.isStopsMode
            ? 'How many stops prior should the alarm go off?'
            : widget.isDistanceMode
            ? 'Enter distance (km)'
            : 'Enter time (minutes)',
      ),
      content: TextField(
        controller: _controller,
        keyboardType: TextInputType.numberWithOptions(
          decimal: widget.isDistanceMode && !widget.isStopsMode,
        ),
        decoration: InputDecoration(
          hintText:
              widget.isStopsMode
                  ? 'Number of stops (1 - 10)'
                  : widget.isDistanceMode
                  ? 'Distance in km (0.5 - 10)'
                  : 'Time in minutes (1 - 60)',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () {
            final value = double.tryParse(_controller.text.trim());
            if (value != null) {
              Navigator.of(context).pop(value);
            } else {
              Navigator.of(context).pop();
            }
          },
          child: const Text('OK'),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}
