// docs/annotated/screens/homescreen.annotated.dart
// Purpose: Line-by-line annotated copy of `lib/screens/homescreen.dart`.
// Scope: Destination search UX, recent locations, map interactions, metro/threshold modes, directions fetch, tracking bootstrap.

import 'dart:async'; // Debounce timers; async ops.
import 'dart:developer' as dev; // Structured logging for diagnostics.
import 'package:flutter/material.dart'; // UI scaffolding and widgets.
import 'package:google_fonts/google_fonts.dart'; // Title font styling.
import 'package:google_maps_flutter/google_maps_flutter.dart'; // Map and LatLng.
import 'package:geolocator/geolocator.dart'; // Location and distance utils.
import 'package:geowake2/services/permission_service.dart'; // Permission request flow.
import 'package:geowake2/screens/otherimpservices/recent_locations_service.dart'; // Persistence of recents.
import 'package:geowake2/services/places_service.dart'; // Autocomplete and details.
import 'package:geowake2/services/metro_stop_service.dart'; // Metro validation.
import 'package:geowake2/screens/settingsdrawer.dart'; // Settings drawer widget.
import 'package:geowake2/services/trackingservice.dart'; // Tracking bootstrap.
import 'package:flutter_background_service/flutter_background_service.dart'; // Background comms.
import 'package:connectivity_plus/connectivity_plus.dart'; // Connectivity state.
import 'package:battery_plus/battery_plus.dart'; // Battery monitoring.
import 'package:geowake2/services/api_client.dart'; // Reverse geocoding for tap-to-set.
// import 'package:geowake2/services/direction_service.dart'; // Legacy import, intentionally disabled.
import 'package:geowake2/services/offline_coordinator.dart'; // Cache-first routing.

class HomeScreen extends StatefulWidget { // Stateful for rich interactions and subscriptions.
  const HomeScreen({super.key}); // Const constructor.
  @override
  HomeScreenState createState() => HomeScreenState(); // Create state type.
}

class HomeScreenState extends State<HomeScreen> { // Primary UI controller for the home screen.
  final TextEditingController _searchController = TextEditingController(); // Input controller.
  final FocusNode _searchFocus = FocusNode(); // Focus mgmt for showing recents.
  Timer? _debounce; // Debounce timer for autocomplete.
  String? _currentCountryCode; // For country-biased autocomplete.

  List<Map<String, dynamic>> _recentLocations = []; // Local recent entries.
  List<Map<String, dynamic>> _autocompleteResults = []; // Merged local + remote suggestions.
  Map<String, dynamic>? _selectedLocation; // Chosen destination.

  late PlacesService _placesService; // Service instance for places APIs.

  bool _useDistanceMode = true; // false => time mode.
  bool _metroMode = false; // If true, distance-mode becomes stops-mode.
  double _distanceSliderValue = 5.0; // km
  double _timeSliderValue = 15.0; // minutes
  double _stopsSliderValue = 2.0; // stops
  bool _isLoading = false; // Button spinner state.
  bool _isTracking = false; // Disable inputs while tracking init.
  bool _noConnectivity = false; // Connectivity banner.
  bool _lowBattery = false; // Battery badge.
  late OfflineCoordinator _offline; // Cache-first routing.

  LatLng? _currentPosition; // Last known location for map and bias.
  final Completer<GoogleMapController> _mapController = Completer(); // Map controller future.
  Set<Marker> _markers = {}; // Map markers (current and selected).
  // Tap handling state for single vs double tap on map // Detect and distinguish double-tap vs single-tap.
  Timer? _tapTimer; // Debouncing timer for map taps.
  DateTime? _lastTapAt; // Timestamp of last tap.
  LatLng? _lastTapLatLng; // Position of last tap.
  double _lastZoom = 12.0; // Map zoom tracking.

  // Battery instance // Battery API handle.
  final Battery _battery = Battery();

  // Subscription for connectivity changes remains // Keep stream sub to update offline flag.
  late StreamSubscription<List<ConnectivityResult>> _connectivitySubscription; // Connectivity+ emits list.

  @override
  void initState() { // Initialize services, subscriptions, and initial state.
    super.initState(); // Base init.
    _placesService = PlacesService(); // Create places service.
    _loadRecentLocations(); // Hydrate recents from storage.
    _initBatteryMonitoring(); // Start battery listener.
    _offline = OfflineCoordinator(initialOffline: false); // Start online by default.

    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((results) { // Observe connectivity changes.
      if (!mounted) return; // Guard if widget disposed.
      setState(() {
        _noConnectivity = results.contains(ConnectivityResult.none); // Offline if no transport.
      });
      _offline.setOffline(_noConnectivity); // Inform offline coordinator for caching behavior.
      // Inform tracking service about connectivity for reroute gating // Sync with tracking layer.
      try {
        TrackingService().setOnline(!_noConnectivity); // Flip online flag.
      } catch (_) {}
    });

    _getCurrentLocation().then((pos) async { // Get initial location, then update map and country code.
      if (!mounted) return; // Bail if disposed.
      if (pos != null) {
        setState(() { // Update map state.
          _currentPosition = LatLng(pos.latitude, pos.longitude); // Store geolocation.
          _markers = { // Show current location marker.
            Marker(
              markerId: const MarkerId('currentLocation'),
              position: _currentPosition!,
              infoWindow: const InfoWindow(title: 'Current Location'),
            ),
          };
        });
        await _getCountryCode(); // Reverse-geocode to country for autocomplete bias.
      }
    });

    _searchFocus.addListener(() { // When search gains focus, show recents; when loses, hide suggestions.
      if (!mounted) return; // Guard dispose.
      if (_searchFocus.hasFocus && _searchController.text.isEmpty) { // Focus with empty query => top recents.
        _showTopRecentLocations(); // Show 3 recent locations.
      } else if (!_searchFocus.hasFocus) { // Unfocused => hide.
        setState(() => _autocompleteResults = []); // Clear list.
      }
    });
  }

  Future<void> _setDestinationFromLatLng(LatLng position) async { // Set destination by reverse-geocoding a map tap.
    try {
      final lat = position.latitude; // Extract lat.
      final lng = position.longitude; // Extract lng.
      final result = await ApiClient.instance.geocode(latlng: '$lat,$lng'); // Server reverse geocode.
      final desc = (result != null ? (result['formatted_address'] ?? result['name']) : null) ?? 'Dropped pin'; // Prefer address, fallback.
      await _setSelectedLocation(desc, lat, lng); // Update selection and map.
    } catch (e) {
      dev.log('Reverse geocode failed on map tap: $e', name: 'HomeScreen'); // Log failure.
      await _setSelectedLocation('Dropped pin', position.latitude, position.longitude); // Fallback to coordinates.
    }
  }

  Future<void> _handleMapTap(LatLng position) async { // Double-tap zoom vs single-tap select.
    final now = DateTime.now(); // Current time.
    final isQuickSecondTap = _lastTapAt != null && now.difference(_lastTapAt!).inMilliseconds < 300; // Double-tap window.
    final isNearPrevious = _lastTapLatLng != null &&
        Geolocator.distanceBetween( // Distance between taps.
              _lastTapLatLng!.latitude,
              _lastTapLatLng!.longitude,
              position.latitude,
              position.longitude,
            ) < 40; // within ~40 meters counts as same spot for double-tap

    _lastTapAt = now; // Update last tap timestamp.
    _lastTapLatLng = position; // Update last tap location.

    // If this looks like a double-tap: zoom in and cancel pending single-tap action
    if (isQuickSecondTap && isNearPrevious) {
      _tapTimer?.cancel(); // Cancel pending single-tap.
      if (_mapController.isCompleted) { // If map ready
        final controller = await _mapController.future; // Await controller.
        final targetZoom = (_lastZoom.isFinite ? _lastZoom : 12.0) + 1.0; // Compute next zoom.
        controller.animateCamera(CameraUpdate.newLatLngZoom(position, targetZoom)); // Zoom in at tap point.
      }
      return; // Done handling double-tap.
    }

    // Debounce single-tap to allow time to detect a potential double-tap
    _tapTimer?.cancel(); // Cancel previous timer.
    _tapTimer = Timer(const Duration(milliseconds: 280), () async { // Short delay to confirm single tap.
      await _setDestinationFromLatLng(position); // Reverse-geocode and select.
    });
  }

  Future<void> _initBatteryMonitoring() async { // Monitor battery level and set low-battery UI flag.
    final int initialLevel = await _battery.batteryLevel; // Read initial level.
    if (!mounted) return; // Guard.
    setState(() => _lowBattery = (initialLevel < 25)); // Consider <25% low.
    _battery.onBatteryStateChanged.listen((state) async { // Subscribe to state changes.
      final level = await _battery.batteryLevel; // Re-read level on change.
      if (!mounted) return; // Guard.
      setState(() => _lowBattery = (level < 25)); // Update flag.
    });
  }

  Future<void> _getCountryCode() async { // Reverse-geocode current position to ISO country code.
    if (_currentPosition == null) return; // Needs position.
    try {
      final result = await ApiClient.instance
          .geocode(latlng: '${_currentPosition!.latitude},${_currentPosition!.longitude}'); // Server geocode.
      if (result != null) {
        final components = (result['address_components'] as List?) ?? []; // Safe list.
        final countryComponent = components.cast<Map<String, dynamic>?>().firstWhere( // Find country component.
          (c) => c != null && ((c['types'] as List?) ?? []).contains('country'), // Types include 'country'.
          orElse: () => null,
        );
        if (countryComponent != null && mounted) {
          setState(() => _currentCountryCode = countryComponent['short_name']); // Store ISO code.
        }
      }
    } catch (e) {
      dev.log("Error fetching country code via server: $e", name: "HomeScreen"); // Log error.
    }
  }

  Future<void> _loadRecentLocations() async { // Load recents from storage into state.
    final loaded = await RecentLocationsService.getRecentLocations(); // Read list.
    if (mounted) {
      setState(() => _recentLocations = List<Map<String, dynamic>>.from(loaded)); // Normalize to map list.
    }
  }

  void _showTopRecentLocations() { // Show top 3 recents when field focused and empty.
    final top3 = _recentLocations.take(3).toList(); // Take first 3.
    setState(() {
      _autocompleteResults = top3.map((loc) => {...loc, 'isLocal': true}).toList(); // Tag as local entries.
    });
  }

  void _onSearchChanged(String query) { // Debounced autocomplete search handler.
    if (_debounce?.isActive ?? false) _debounce!.cancel(); // Reset timer if active.
    _debounce = Timer(const Duration(milliseconds: 450), () async { // Debounce delay.
      if (query.isEmpty) {
        if (mounted) _showTopRecentLocations(); // If empty, show recents.
        return; // Stop.
      }

      final localMatches = _recentLocations.where((loc) { // Filter recents by substring.
        return (loc['description'] ?? '').toLowerCase().contains(query.toLowerCase()); // Case-insensitive.
      }).map((loc) => {...loc, 'isLocal': true}).toList(); // Tag results as local.

      try {
        final remoteResults = await _placesService.fetchAutocompleteResults( // Query server for autocomplete.
          query,
          countryCode: _currentCountryCode,
          lat: _currentPosition?.latitude,
          lng: _currentPosition?.longitude,
        );

        final combined = [...localMatches]; // Start with local.
        for (var remote in remoteResults) { // Merge remote with de-duplication by place_id.
          if (!combined.any((local) => local['place_id'] == remote['place_id'])) {
            combined.add(remote); // Append unique remote.
          }
        }
        
        if (mounted) setState(() => _autocompleteResults = combined); // Publish.
      } catch (e) {
        dev.log("Error fetching autocomplete results: $e", name: "HomeScreen"); // Log but don’t crash.
      }
    });
  }

  // =======================================================================
  // CORRECTED LOGIC FOR SELECTING AND SAVING A LOCATION
  // =======================================================================
  Future<void> _onSuggestionSelected(Map<String, dynamic> suggestion) async { // Handle selection of suggestion.
    setState(() => _autocompleteResults = []); // Clear list.
    _searchFocus.unfocus(); // Dismiss keyboard.

    final placeId = suggestion['place_id']; // Unique ID for place.
    if (placeId == null) { // Guard.
      dev.log("Error: Suggestion is missing a place_id.", name: "HomeScreen"); // Log error.
      return; // Abort.
    }

    try {
      final details = await _placesService.fetchPlaceDetails(placeId); // Resolve to coordinates and description.
      if (details != null) {
        final desc = details['description'] ?? 'Unknown Location'; // Prefer description.
        final lat = details['lat']; // Lat value.
        final lng = details['lng']; // Lng value.
        
        // Update the map and selected location state // Reflect selection in UI.
        await _setSelectedLocation(desc, lat, lng); // Update state + map camera.
        
        // Correctly save the location with its unique place_id // Persist recents deduped by place_id.
        await _addToRecentLocations(desc, placeId, lat, lng);
      }
    } catch (e) {
      dev.log("Error fetching place details: $e", name: "HomeScreen"); // Record issue.
    }
  }

  Future<void> _setSelectedLocation(String desc, double lat, double lng) async { // Apply selection and update map.
    setState(() {
      _selectedLocation = {'description': desc, 'lat': lat, 'lng': lng}; // Save selection.
      _searchController.text = desc; // Populate field with description.
      _markers = { // Replace with single draggable destination marker.
        Marker(
          markerId: const MarkerId('selectedMarker'),
          position: LatLng(lat, lng),
          infoWindow: InfoWindow(title: desc),
          draggable: true, // Allow refining position by drag.
          onDragEnd: (newPos) { // Update selection when user drags marker.
            setState(() {
              _selectedLocation?['lat'] = newPos.latitude; // Update lat.
              _selectedLocation?['lng'] = newPos.longitude; // Update lng.
            });
          },
        ),
      };
    });
    final controller = await _mapController.future; // Wait for map controller.
    controller.animateCamera(CameraUpdate.newLatLngZoom(LatLng(lat, lng), 14)); // Center and zoom.
  }

  // =======================================================================
  // CORRECTED LOGIC FOR SAVING RECENTS USING UNIQUE 'place_id'
  // =======================================================================
  Future<void> _addToRecentLocations(String desc, String placeId, double lat, double lng) async { // Persist recents with dedupe.
    // 1. Remove any existing entry with the same UNIQUE place_id.
    _recentLocations.removeWhere((loc) => loc['place_id'] == placeId); // Dedupe by ID.
    
    // 2. Add the new location data to the top of the list.
    _recentLocations.insert(0, { // Add as most recent.
      'description': desc, 
      'place_id': placeId, // Store the unique ID
      'lat': lat, 
      'lng': lng
    });

    // 3. Keep the list from getting too long.
    if (_recentLocations.length > 10) {
      _recentLocations = _recentLocations.sublist(0, 10); // Trim to last 10.
    }

    // 4. Save the updated list to device storage.
    await RecentLocationsService.saveRecentLocations(_recentLocations); // Persist to storage.
  }

  Future<void> _removeRecentLocation(Map<String, dynamic> suggestion) async { // Remove from recents.
    setState(() {
      _recentLocations.removeWhere((loc) => loc['place_id'] == suggestion['place_id']); // Remove matching place_id.
      _autocompleteResults.removeWhere((item) => item['place_id'] == suggestion['place_id']); // Update displayed list.
    });
    await RecentLocationsService.saveRecentLocations(_recentLocations); // Persist.
  }

  // The rest of your file remains the same... // Continuation of handlers and UI.
  
  Future<void> _onWakeMePressed() async { // Primary action: validate permissions and start routing/tracking.
    if (_selectedLocation == null) { // Require destination selection.
      _showErrorDialog("Destination Missing", "Please select a valid destination."); // Inform user.
      return; // Abort.
    }
    setState(() { _isLoading = true; }); // Show spinner.

    // This is the updated block that uses our new, robust service // Friendly staged permissions.
    final permissionService = PermissionService(context); // Create permission handler.
    final bool canProceed = await permissionService.requestEssentialPermissions(); // Request.
    
    if (!mounted) return; // Guard.
    
    if (canProceed) { // Permissions granted.
      // Permissions were granted, proceed with tracking!
      setState(() => _isTracking = true); // Lock controls.
      await _proceedWithDirections(); // Continue.
    } else {
      // Permissions were denied. The service already showed the user a dialog.
      // We just need to reset the loading state.
      setState(() => _isLoading = false); // Reset spinner.
    }
  }

  Future<void> _proceedWithDirections() async { // Fetch directions and start tracking.
    try {
      final Position? currentPosition = await _getCurrentLocation(); // Get current location.
      if (currentPosition == null) { // Bail on failure.
        _showErrorDialog("Location Error", "Could not get your current location. Please enable location services."); // Alert.
        setState(() {
          _isTracking = false; // Reset flags.
          _isLoading = false;
        });
        return;
      }

      double destLat = _selectedLocation!['lat']; // Destination lat.
      double destLng = _selectedLocation!['lng']; // Destination lng.
      double userLat = currentPosition.latitude; // User lat.
      double userLng = currentPosition.longitude; // User lng.

      if (_metroMode) { // Metro validation path.
        final validationResult = await MetroStopService.validateMetroRoute( // Validate start/destination stops.
          startLocation: LatLng(userLat, userLng),
          destination: LatLng(destLat, destLng),
        );
        if (!mounted) return; // Guard dispose.
        if (!validationResult.isValid || validationResult.closestStop == null) { // No valid metro route.
          _showErrorDialog("Metro Route Unavailable", validationResult.errorMessage ?? "No valid metro route found."); // Alert.
          setState(() {
            _isTracking = false; // Reset flags.
            _isLoading = false;
          });
          return; // Abort.
        } else {
          destLat = validationResult.closestStop!.location.latitude; // Snap destination to closest stop.
          destLng = validationResult.closestStop!.location.longitude; // Snap lng.
        }
      }

      final directions = await _fetchDirections(userLat, userLng, destLat, destLng); // Cache-first fetch.
      final initialETA = directions['routes'][0]['legs'][0]['duration']['value'] as int; // Seconds.
      
      final trackingService = TrackingService(); // Access tracking service.
      // Register this route so ActiveRouteManager can snap/switch // Prepare for tracking: segment geometry and registry.
      try {
        trackingService.registerRouteFromDirections(
          directions: directions,
          origin: LatLng(userLat, userLng),
          destination: LatLng(destLat, destLng),
          transitMode: _metroMode,
          destinationName: _selectedLocation?['description'] ?? 'Your Destination',
        );
      } catch (e) {
        dev.log('Failed to register route with TrackingService: $e', name: 'HomeScreen'); // Non-fatal.
      }
      // Compute alarm mode/value. For metro+stops, use stops-based threshold.
      String alarmMode = _useDistanceMode ? 'distance' : 'time'; // Default mode.
      double alarmValue; // Threshold.
      if (_metroMode && _useDistanceMode) { // Stops mode.
        // When metro mode and 'stops' selected, send stops threshold directly
        alarmMode = 'stops';
        alarmValue = _stopsSliderValue; // Stops value.
      } else {
        alarmValue = _useDistanceMode ? _distanceSliderValue : _timeSliderValue; // Distance km or time min.
      }

      await trackingService.startTracking( // Start tracking service session.
        destination: LatLng(destLat, destLng),
        destinationName: _selectedLocation?['description'] ?? 'Your Destination',
        alarmMode: alarmMode,
        alarmValue: alarmValue,
      );

      FlutterBackgroundService().invoke("updateRouteData", {"initialETA": initialETA}); // Send initial ETA to background.
      
      final Map<String, dynamic> mapArgs = { // Prepare navigation args.
        'destination': _searchController.text,
        'mode': _metroMode && _useDistanceMode ? 'stops' : (_useDistanceMode ? 'distance' : 'time'),
        'value': _metroMode && _useDistanceMode ? _stopsSliderValue : (_useDistanceMode ? _distanceSliderValue : _timeSliderValue),
        'metroMode': _metroMode,
        'directions': directions,
        'userLat': userLat,
        'userLng': userLng,
        'lat': destLat,
        'lng': destLng,
      };

      if (!mounted) return; // Guard.
      Navigator.pushReplacementNamed(context, '/preloadMap', arguments: mapArgs); // Navigate into map flow.
      if (mounted) {
        setState(() {
          _isLoading = false; // Stop spinner.
        });
      }

    } catch (e) {
      dev.log("Error in _proceedWithDirections: $e", name: "HomeScreen"); // Log error.
      if(mounted) {
         _showErrorDialog("Route Error", "Could not calculate the route. Please try again."); // Alert.
         setState(() {
           _isTracking = false; // Reset flags on failure.
           _isLoading = false;
         });
      }
    }
  }

  // Removed legacy km-per-stop estimator (now use stops mode directly) // Simplified policy.

  void _showErrorDialog(String title, String message) { // Standard error dialog.
    if (!mounted) return; // Guard.
    showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(title), // Dialog title.
          content: Text(message), // Dialog body.
          actions: <Widget>[
            TextButton(
              child: const Text('OK'), // Dismiss button.
              onPressed: () => Navigator.of(context).pop(), // Pop dialog.
            ),
          ],
        );
      },
    );
  }

  Future<Position?> _getCurrentLocation() async { // Current GPS position helper.
    try {
      return await Geolocator.getCurrentPosition(); // Delegate to geolocator.
    } catch (e) {
      return null; // Graceful failure.
    }
  }

  Future<Map<String, dynamic>> _fetchDirections( // Cache-first directions fetch.
    double startLat, double startLng, double endLat, double endLng) async {
    final threshold = _useDistanceMode
        ? (_metroMode ? _stopsSliderValue : _distanceSliderValue)
        : _timeSliderValue; // Compute threshold param.
    try {
      final res = await _offline.getRoute( // Ask OfflineCoordinator to retrieve/compute route.
        origin: LatLng(startLat, startLng),
        destination: LatLng(endLat, endLng),
        isDistanceMode: _useDistanceMode,
        threshold: threshold,
        transitMode: _metroMode,
        forceRefresh: false,
      );
      return res.directions; // Return raw directions payload.
    } catch (e) {
      if (_noConnectivity) {
        throw Exception("Offline with no cached route available."); // Meaningful error.
      }
      throw Exception("Failed to fetch directions: $e"); // Propagate error context.
    }
  }

  // (Reverted) No special blocking for absence of metro in directions // Managed earlier.

  @override
  void dispose() { // Clean up controllers and subscriptions.
    _debounce?.cancel(); // Cancel debounce timer.
    _searchController.dispose(); // Dispose controller.
    _searchFocus.dispose(); // Dispose focus node.
    _connectivitySubscription.cancel(); // Cancel connectivity stream.
    super.dispose(); // Parent dispose.
  }

  @override
  Widget build(BuildContext context) { // Compose UI tree for home screen.
    final screenWidth = MediaQuery.of(context).size.width; // Screen width.
    final screenHeight = MediaQuery.of(context).size.height; // Screen height.
    final bool isDarkMode = Theme.of(context).brightness == Brightness.dark; // Dark mode flag.
    final Color searchBarFillColor = isDarkMode ? Colors.grey[800]! : Colors.grey[200]!; // Adaptive fill.

    return Scaffold( // Page scaffold with drawer, app bar, and content.
      drawer: const SettingsDrawer(), // Left-side drawer.
      appBar: AppBar( // Top app bar.
        title: Text( // Title with brand font.
          'GeoWake',
          style: GoogleFonts.pacifico(
            textStyle: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: screenWidth * 0.07,
            ),
          ),
        ),
        actions: [ // App bar actions.
          Row(
            children: [
              const Text('Metro Mode', style: TextStyle(fontSize: 12)), // Label.
              Switch(
                value: _metroMode, // Current state.
                onChanged: _isTracking ? null : (val) => setState(() => _metroMode = val), // Disabled when tracking.
              ),
              const SizedBox(width: 8), // Spacing.
            ],
          ),
        ],
      ),
      bottomNavigationBar: Container( // Placeholder for ad banner.
        height: screenHeight * 0.06,
        color: Colors.grey[300],
        child: const Center(child: Text('Ad Banner Placeholder')), // Stub.
      ),
      body: SafeArea( // Inset-aware content.
        child: SingleChildScrollView( // Scroll content.
          padding: EdgeInsets.all(screenWidth * 0.04), // Responsive padding.
          child: AbsorbPointer( // Disable inputs during tracking init.
            absorbing: _isTracking,
            child: Column( // Main vertical layout.
              crossAxisAlignment: CrossAxisAlignment.stretch, // Stretch children to width.
              children: [
                if (_noConnectivity)
                  Container( // Offline banner.
                    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
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
                TextField( // Destination input.
                  focusNode: _searchFocus,
                  controller: _searchController,
                  onChanged: _onSearchChanged,
                  style: TextStyle(color: isDarkMode ? Colors.white : Colors.black), // Adaptive text color.
                  decoration: InputDecoration( // Search field styling.
                    hintText: 'Enter your destination',
                    prefixIcon: const Icon(Icons.search),
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
                    hintStyle: TextStyle(color: isDarkMode ? Colors.white70 : Colors.black54),
                    prefixIconColor: isDarkMode ? Colors.white70 : Colors.black54,
                  ),
                ),
                SizedBox(height: screenHeight * 0.01), // Small spacing.
                if (_autocompleteResults.isNotEmpty)
                  Container( // Suggestion popup.
                    decoration: BoxDecoration(
                      color: isDarkMode ? Colors.grey[800] : Colors.white,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: ListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(), // Let outer scroll view handle scroll.
                      itemCount: _autocompleteResults.length,
                      itemBuilder: (context, index) {
                        final suggestion = _autocompleteResults[index]; // Row data.
                        return ListTile(
                          title: Text(suggestion['description'] ?? 'Unknown'), // Display text.
                          onTap: () => _onSuggestionSelected(suggestion), // Select handler.
                          trailing: suggestion['isLocal'] == true
                              ? GestureDetector( // Local entries get a remove control.
                                  onTap: () => _removeRecentLocation(suggestion), // Remove handler.
                                  child: Container(
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: Colors.grey.shade400,
                                    ),
                                    padding: const EdgeInsets.all(4),
                                    child: const Icon(Icons.close, size: 16),
                                  ),
                                )
                              : null,
                        );
                      },
                    ),
                  ),
                SizedBox(height: screenHeight * 0.02), // Spacing.
                ClipRRect( // Rounded map container.
                  borderRadius: BorderRadius.circular(12),
                  child: SizedBox(
                    height: screenHeight * 0.3, // Map height.
                    child: GoogleMap(
                      initialCameraPosition: CameraPosition(
                        target: _currentPosition ?? const LatLng(12.9716, 77.5946), // Bengaluru
                        zoom: 12,
                      ),
                      markers: _markers,
                      onTap: _handleMapTap, // Tap handler with double-tap zoom logic.
                      onCameraMove: (position) {
                        _lastZoom = position.zoom; // Track zoom value.
                      },
                      onMapCreated: (controller) {
                        if (!_mapController.isCompleted) {
                           _mapController.complete(controller); // Complete once.
                        }
                      },
                    ),
                  ),
                ),
                SizedBox(height: screenHeight * 0.03), // Spacing.
                Row( // Mode toggle row.
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text('Time'), // Left label.
                    Switch(
                      value: _useDistanceMode, // Current toggle.
                      onChanged: (val) => setState(() => _useDistanceMode = val), // Toggle handler.
                    ),
                    Text(_metroMode ? 'Stops' : 'Distance'), // Right label changes with metro.
                  ],
                ),
                SizedBox(height: screenHeight * 0.02), // Spacing.
                GestureDetector( // Open value dialog.
                  onTap: () async {
                    final newValue = await showDialog<double>(
                      context: context,
                      builder: (_) {
                        return _EnterValueDialog(
                          initialValue: _useDistanceMode
                              ? (_metroMode ? _stopsSliderValue : _distanceSliderValue)
                              : _timeSliderValue,
                          isDistanceMode: _useDistanceMode && !_metroMode,
                          isStopsMode: _useDistanceMode && _metroMode,
                        );
                      },
                    );
                    if (!mounted) return; // Guard.
                    if (newValue != null) {
                      setState(() {
                        if (_useDistanceMode) {
                          if (_metroMode) {
                            _stopsSliderValue = newValue.clamp(1.0, 10.0); // Bounds for stops.
                          } else {
                            _distanceSliderValue = newValue.clamp(0.5, 10.0); // Bounds for km.
                          }
                        } else {
                          _timeSliderValue = newValue.clamp(1.0, 60.0); // Bounds for minutes.
                        }
                      });
                    }
                  },
                  child: Container( // Inline value display.
                    padding: EdgeInsets.symmetric(
                      vertical: screenHeight * 0.015,
                      horizontal: screenWidth * 0.04,
                    ),
                    decoration: BoxDecoration(
                      color: isDarkMode ? Colors.grey[700] : Colors.grey[200],
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
                      style: TextStyle(fontSize: screenWidth * 0.045), // Responsive font.
                    ),
                  ),
                ),
                SizedBox(height: screenHeight * 0.015), // Spacing.
                Slider( // Inline slider for quick adjustments.
                  value: _useDistanceMode
                      ? (_metroMode ? _stopsSliderValue : _distanceSliderValue)
                      : _timeSliderValue,
                  min: _useDistanceMode ? (_metroMode ? 1.0 : 0.5) : 1.0,
                  max: _useDistanceMode ? (_metroMode ? 10.0 : 10.0) : 60.0,
                  divisions: _useDistanceMode ? (_metroMode ? 9 : 19) : 59,
                  label: _useDistanceMode
                      ? (_metroMode ? _stopsSliderValue.toStringAsFixed(0) : _distanceSliderValue.toStringAsFixed(1))
                      : _timeSliderValue.toStringAsFixed(0),
                  onChanged: (val) {
                    setState(() {
                      if (_useDistanceMode) {
                        if (_metroMode) {
                          // Stops slider should be integer-like in feel
                          _stopsSliderValue = val.round().toDouble(); // Snap to integer.
                        } else {
                          _distanceSliderValue = val; // Free slider.
                        }
                      } else {
                        _timeSliderValue = val; // Update minutes.
                      }
                    });
                  },
                ),
                SizedBox(height: screenHeight * 0.03), // Spacing.
                ElevatedButton( // Primary CTA.
                  onPressed: (_selectedLocation == null ||
                          _searchController.text.isEmpty ||
                          _isLoading ||
                          _isTracking)
                      ? null
                      : _onWakeMePressed, // Guarded action.
                  child: _isLoading
                      ? Row( // Loading indicator.
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
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
                if (_lowBattery)
                  Padding( // Low battery icon button.
                    padding: EdgeInsets.only(top: screenHeight * 0.02),
                    child: Row(
                      children: [
                        const Spacer(),
                        _buildAlertButton(
                          icon: Icons.battery_alert,
                          onPressed: () {}, // Hook for battery tips.
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      // No floating action button in production
    );
  }

  Widget _buildAlertButton({ // Small rounded alert button builder.
    required IconData icon,
    required VoidCallback onPressed,
  }) {
    return Material(
      color: Colors.redAccent, // Red badge.
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), // Rounded rect.
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          child: Icon(icon, color: Colors.white, size: 24), // White icon.
        ),
      ),
    );
  }
}

class _EnterValueDialog extends StatefulWidget { // Dialog to fine-tune threshold value.
  final double initialValue; // Seed value.
  final bool isDistanceMode; // True when distance mode.
  final bool isStopsMode; // True when stops sub-mode.
  const _EnterValueDialog({
    required this.initialValue,
    required this.isDistanceMode,
    this.isStopsMode = false,
  });
  @override
  State<_EnterValueDialog> createState() => _EnterValueDialogState(); // State factory.
}

class _EnterValueDialogState extends State<_EnterValueDialog> { // Dialog state holds text controller.
  late TextEditingController _controller; // Text input control.
  @override
  void initState() {
    super.initState();
    _controller = TextEditingController( // Pre-fill with formatted value.
      text: widget.isDistanceMode
          ? widget.initialValue.toStringAsFixed(1)
          : widget.isStopsMode
              ? widget.initialValue.toStringAsFixed(0)
              : widget.initialValue.toStringAsFixed(0),
    );
  }
  @override
  Widget build(BuildContext context) { // Render dialog.
    return AlertDialog(
      title: Text(
        widget.isDistanceMode
            ? (widget.isStopsMode ? 'Enter stops' : 'Enter distance (km)')
            : 'Enter time (minutes)'
      ),
      content: TextField(
        controller: _controller,
        keyboardType: TextInputType.numberWithOptions(
          decimal: widget.isDistanceMode && !widget.isStopsMode, // Allow decimal for km only.
        ),
        decoration: InputDecoration(
          hintText: widget.isDistanceMode
              ? (widget.isStopsMode ? 'Number of stops (1 - 10)' : 'Distance in km (0.5 - 10)')
              : 'Time in minutes (1 - 60)',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(), // Cancel.
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () {
            final value = double.tryParse(_controller.text.trim()); // Parse input.
            if (value != null) {
              Navigator.of(context).pop(value); // Return value.
            } else {
              Navigator.of(context).pop(); // Dismiss without change.
            }
          },
          child: const Text('OK'),
        ),
      ],
    );
  }
  @override
  void dispose() {
    _controller.dispose(); // Clean up controller.
    super.dispose();
  }
}

// Post-block notes:
// - Robust UX around destination entry: local recents + remote autocomplete with debouncing and de-duplication.
// - Map interactions: single-tap selects via reverse geocode; double-tap zooms.
// - OfflineCoordinator mediates cache-first routing; TrackingService registers route and kicks off tracking.
// - Metro mode switches distance to stops; time mode remains in minutes; thresholds editable via slider and dialog.
// - Connectivity and battery signals wire into banners and badges; permissions gate tracking start.

// End-of-file summary:
// - This screen orchestrates selecting a destination and starting background tracking with alarms.
// - Integrates multiple services (places, metro validation, offline cache, tracking).
// - Cleans up subscriptions; guards setState with `mounted`; uses responsive sizing for better UX.
