import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart';
import 'package:geowake2/services/permission_service.dart';
import 'package:geowake2/screens/otherimpservices/recent_locations_service.dart';
import 'package:geowake2/services/places_service.dart';
import 'package:geowake2/services/metro_stop_service.dart';
import 'settingsdrawer.dart';
import 'package:geowake2/services/trackingservice.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:geowake2/config/app_config.dart';
import 'package:geowake2/services/api_client.dart';



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
  bool _isLoading = false;
  bool _isTracking = false;
  bool _noConnectivity = false;
  bool _lowBattery = false;

  LatLng? _currentPosition;
  final Completer<GoogleMapController> _mapController = Completer();
  Set<Marker> _markers = {};

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

    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((results) {
      if (!mounted) return;
      setState(() {
        _noConnectivity = results.contains(ConnectivityResult.none);
      });
    });

    _getCurrentLocation().then((pos) async {
      if (!mounted) return;
      if (pos != null) {
        setState(() {
          _currentPosition = LatLng(pos.latitude, pos.longitude);
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
    
    final url = Uri.https('maps.googleapis.com', '/maps/api/geocode/json', {
      'latlng': '${_currentPosition!.latitude},${_currentPosition!.longitude}',
      'key': AppConfig.googleMapsApiKey
    });
    
    try {
      final response = await http.get(url);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['status'] == 'OK' && data['results'].isNotEmpty) {
          final components = data['results'][0]['address_components'] as List;
          final countryComponent = components.firstWhere(
            (c) => (c['types'] as List).contains('country'),
            orElse: () => null,
          );
          if (countryComponent != null && mounted) {
            setState(() => _currentCountryCode = countryComponent['short_name']);
          }
        }
      }
    } catch (e) {
      dev.log("Error fetching country code: $e", name: "HomeScreen");
    }
  }

  Future<void> _loadRecentLocations() async {
    final loaded = await RecentLocationsService.getRecentLocations();
    if (mounted) {
      setState(() => _recentLocations = List<Map<String, dynamic>>.from(loaded));
    }
  }

  void _showTopRecentLocations() {
    final top3 = _recentLocations.take(3).toList();
    setState(() {
      _autocompleteResults = top3.map((loc) => {...loc, 'isLocal': true}).toList();
    });
  }

  void _onSearchChanged(String query) {
    if (_debounce?.isActive ?? false) _debounce!.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), () async {
      if (query.isEmpty) {
        if (mounted) _showTopRecentLocations();
        return;
      }

      final localMatches = _recentLocations.where((loc) {
        return (loc['description'] ?? '').toLowerCase().contains(query.toLowerCase());
      }).map((loc) => {...loc, 'isLocal': true}).toList();

      try {
        final remoteResults = await _placesService.fetchAutocompleteResults(
          query,
          countryCode: _currentCountryCode,
          lat: _currentPosition?.latitude,
          lng: _currentPosition?.longitude,
        );

        final combined = [...localMatches];
        for (var remote in remoteResults) {
          if (!combined.any((local) => local['place_id'] == remote['place_id'])) {
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
  Future<void> _addToRecentLocations(String desc, String placeId, double lat, double lng) async {
    // 1. Remove any existing entry with the same UNIQUE place_id.
    _recentLocations.removeWhere((loc) => loc['place_id'] == placeId);
    
    // 2. Add the new location data to the top of the list.
    _recentLocations.insert(0, {
      'description': desc, 
      'place_id': placeId, // Store the unique ID
      'lat': lat, 
      'lng': lng
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
      _recentLocations.removeWhere((loc) => loc['place_id'] == suggestion['place_id']);
      _autocompleteResults.removeWhere((item) => item['place_id'] == suggestion['place_id']);
    });
    await RecentLocationsService.saveRecentLocations(_recentLocations);
  }

  // The rest of your file remains the same...
  
  Future<void> _onWakeMePressed() async {
    if (_noConnectivity) {
      _showErrorDialog("Internet Required", "An internet connection is needed to fetch route data.");
      return;
    }
    if (_selectedLocation == null) {
      _showErrorDialog("Destination Missing", "Please select a valid destination.");
      return;
    }
    setState(() { _isLoading = true; });

    // This is the updated block that uses our new, robust service
    final permissionService = PermissionService(context);
    final bool canProceed = await permissionService.requestEssentialPermissions();
    
    if (!mounted) return;
    
    if (canProceed) {
      // Permissions were granted, proceed with tracking!
      setState(() => _isTracking = true);
      await _proceedWithDirections();
    } else {
      // Permissions were denied. The service already showed the user a dialog.
      // We just need to reset the loading state.
      setState(() => _isLoading = false);
    }
  }

  Future<void> _proceedWithDirections() async {
    try {
      final Position? currentPosition = await _getCurrentLocation();
      if (currentPosition == null) {
        _showErrorDialog("Location Error", "Could not get your current location. Please enable location services.");
        setState(() => _isTracking = false);
        return;
      }

      double destLat = _selectedLocation!['lat'];
      double destLng = _selectedLocation!['lng'];
      double userLat = currentPosition.latitude;
      double userLng = currentPosition.longitude;

      if (_metroMode) {
        final validationResult = await MetroStopService.validateMetroRoute(
          startLocation: LatLng(userLat, userLng),
          destination: LatLng(destLat, destLng),
        );
        if (!mounted) return;
        if (!validationResult.isValid || validationResult.closestStop == null) {
          _showErrorDialog("Metro Route Unavailable", validationResult.errorMessage ?? "No valid metro route found.");
          setState(() => _isTracking = false);
          return;
        } else {
          destLat = validationResult.closestStop!.location.latitude;
          destLng = validationResult.closestStop!.location.longitude;
        }
      }

      final directions = await _fetchDirections(userLat, userLng, destLat, destLng);
      final initialETA = directions['routes'][0]['legs'][0]['duration']['value'] as int;
      
      final trackingService = TrackingService();
      
      await trackingService.startTracking(
        destination: LatLng(destLat, destLng),
        destinationName: _selectedLocation?['description'] ?? 'Your Destination',
        alarmMode: _useDistanceMode ? 'distance' : 'time',
        alarmValue: _useDistanceMode ? _distanceSliderValue : _timeSliderValue,
      );

      FlutterBackgroundService().invoke("updateRouteData", {"initialETA": initialETA});
      
      final Map<String, dynamic> mapArgs = {
        'destination': _searchController.text,
        'mode': _useDistanceMode ? 'distance' : 'time',
        'value': _useDistanceMode ? _distanceSliderValue : _timeSliderValue,
        'metroMode': _metroMode,
        'directions': directions,
        'userLat': userLat,
        'userLng': userLng,
        'lat': destLat,
        'lng': destLng,
        'apiKey': AppConfig.googleMapsApiKey,
      };

      if (!context.mounted) return;
      Navigator.pushReplacementNamed(context, '/preloadMap', arguments: mapArgs);

    } catch (e) {
      dev.log("Error in _proceedWithDirections: $e", name: "HomeScreen");
      if(mounted) {
         _showErrorDialog("Route Error", "Could not calculate the route. Please try again.");
         setState(() => _isTracking = false);
      }
    }
  }

  void _showErrorDialog(String title, String message) {
    if (!mounted) return;
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
    double startLat, double startLng, double endLat, double endLng) async {
    
    final apiClient = ApiClient.instance;
    
    try {
      final directions = await apiClient.getDirections(
        origin: '$startLat,$startLng',
        destination: '$endLat,$endLng',
        mode: _metroMode ? 'transit' : 'driving',
        transitMode: _metroMode ? 'rail' : null,
      );
      
      if (directions['status'] != 'OK' || (directions['routes'] as List).isEmpty) {
        throw Exception("No feasible route found: ${directions['error_message'] ?? directions['status']}");
      }
      
      return directions;
    } catch (e) {
      throw Exception("Failed to fetch directions: $e");
    }
  }

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
    final Color searchBarFillColor = isDarkMode ? Colors.grey[800]! : Colors.grey[200]!;

    return Scaffold(
      drawer: const SettingsDrawer(),
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
              Switch(
                value: _metroMode,
                onChanged: _isTracking ? null : (val) => setState(() => _metroMode = val),
              ),
              const SizedBox(width: 8),
            ],
          ),
        ],
      ),
      bottomNavigationBar: Container(
        height: screenHeight * 0.06,
        color: Colors.grey[300],
        child: const Center(child: Text('Ad Banner Placeholder')),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.all(screenWidth * 0.04),
          child: AbsorbPointer(
            absorbing: _isTracking,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  focusNode: _searchFocus,
                  controller: _searchController,
                  onChanged: _onSearchChanged,
                  style: TextStyle(color: isDarkMode ? Colors.white : Colors.black),
                  decoration: InputDecoration(
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
                          title: Text(suggestion['description'] ?? 'Unknown'),
                          onTap: () => _onSuggestionSelected(suggestion),
                          trailing: suggestion['isLocal'] == true
                              ? GestureDetector(
                                  onTap: () => _removeRecentLocation(suggestion),
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
                SizedBox(height: screenHeight * 0.02),
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: SizedBox(
                    height: screenHeight * 0.3,
                    child: GoogleMap(
                      initialCameraPosition: CameraPosition(
                        target: _currentPosition ?? const LatLng(12.9716, 77.5946), // Bengaluru
                        zoom: 12,
                      ),
                      markers: _markers,
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
                    Switch(
                      value: !_useDistanceMode,
                      onChanged: (val) => setState(() => _useDistanceMode = !val),
                    ),
                    const Text('Distance'),
                  ],
                ),
                SizedBox(height: screenHeight * 0.02),
                GestureDetector(
                  onTap: () async {
                    final newValue = await showDialog<double>(
                      context: context,
                      builder: (_) {
                        return _EnterValueDialog(
                          initialValue: _useDistanceMode ? _distanceSliderValue : _timeSliderValue,
                          isDistanceMode: _useDistanceMode,
                        );
                      },
                    );
                    if (!mounted) return;
                    if (newValue != null) {
                      setState(() {
                        if (_useDistanceMode) {
                          _distanceSliderValue = newValue.clamp(0.5, 10.0);
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
                      color: isDarkMode ? Colors.grey[700] : Colors.grey[200],
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: isDarkMode ? Colors.white38 : Colors.grey,
                        width: 1.0,
                      ),
                    ),
                    child: Text(
                      _useDistanceMode
                          ? 'Alert me within ${_distanceSliderValue.toStringAsFixed(1)} km'
                          : 'Alert me in ${_timeSliderValue.toStringAsFixed(0)} min',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: screenWidth * 0.045),
                    ),
                  ),
                ),
                SizedBox(height: screenHeight * 0.015),
                Slider(
                  value: _useDistanceMode ? _distanceSliderValue : _timeSliderValue,
                  min: _useDistanceMode ? 0.5 : 1.0,
                  max: _useDistanceMode ? 10.0 : 60.0,
                  divisions: _useDistanceMode ? 19 : 59,
                  label: _useDistanceMode
                      ? _distanceSliderValue.toStringAsFixed(1)
                      : _timeSliderValue.toStringAsFixed(0),
                  onChanged: (val) {
                    setState(() {
                      if (_useDistanceMode) {
                        _distanceSliderValue = val;
                      } else {
                        _timeSliderValue = val;
                      }
                    });
                  },
                ),
                SizedBox(height: screenHeight * 0.03),
                ElevatedButton(
                  onPressed: (_selectedLocation == null ||
                          _searchController.text.isEmpty ||
                          _isLoading ||
                          _isTracking)
                      ? null
                      : _onWakeMePressed,
                  child: Text(
                    _isLoading ? 'Loading...' : 'Wake Me!',
                    style: TextStyle(fontSize: screenWidth * 0.05),
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
          child: Icon(icon, color: Colors.white, size: 24),
        ),
      ),
    );
  }
}

class _EnterValueDialog extends StatefulWidget {
  final double initialValue;
  final bool isDistanceMode;
  const _EnterValueDialog({
    required this.initialValue,
    required this.isDistanceMode,
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
      text: widget.isDistanceMode
          ? widget.initialValue.toStringAsFixed(1)
          : widget.initialValue.toStringAsFixed(0),
    );
  }
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.isDistanceMode ? 'Enter distance (km)' : 'Enter time (minutes)'),
      content: TextField(
        controller: _controller,
        keyboardType: TextInputType.numberWithOptions(
          decimal: widget.isDistanceMode,
        ),
        decoration: InputDecoration(
          hintText: widget.isDistanceMode ? 'Distance in km (0.5 - 10)' : 'Time in minutes (1 - 60)',
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