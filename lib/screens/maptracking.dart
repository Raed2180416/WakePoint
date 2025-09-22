import 'dart:async';
import 'dart:math';
import 'dart:developer' as dev;
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geowake2/services/polyline_decoder.dart';
import 'package:geowake2/services/direction_service.dart';
import 'package:geowake2/services/polyline_simplifier.dart';
import 'package:geolocator/geolocator.dart';
import 'settingsdrawer.dart';

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
  bool _metroMode = false;
  Set<Marker> _markers = {};
  Set<Polyline> _polylines = {};
  String _etaText = "Calculating ETA...";
  String _distanceText = "Calculating distance...";
  bool _hasValidArgs = false;

  Map<String, dynamic>? directions;

  // StreamSubscription to update the current location marker.
  StreamSubscription<Position>? _locationSubscription;
  LatLng? _currentUserLocation;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final args =
        ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;
    dev.log("MapTrackingScreen received args: ${args.toString()}",
        name: "MapTrackingScreen");
    if (args == null ||
        args['lat'] == null ||
        args['lng'] == null ||
        args['destination'] == null ||
        args['directions'] == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
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
      return;
    }
    _hasValidArgs = true;
    _destinationName = args['destination'];
    _destinationLat = args['lat'];
    _destinationLng = args['lng'];
    _metroMode = args['metroMode'] ?? false;
    double userLat = args['userLat'] ?? 37.422;
    double userLng = args['userLng'] ?? -122.084;
    _currentUserLocation = LatLng(userLat, userLng);
    dev.log("MapTrackingScreen: Destination: $_destinationName, ($_destinationLat, $_destinationLng)",
        name: "MapTrackingScreen");
    dev.log("MapTrackingScreen: Initial user location: ($userLat, $userLng)",
        name: "MapTrackingScreen");

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
    if (directions != null) {
      if (_metroMode) {
        final directionService = DirectionService();
        final segmentedPolylines =
            directionService.buildSegmentedPolylines(directions!, true);
        setState(() {
          _polylines = segmentedPolylines.toSet();
          _isLoading = false;
        });
        _adjustCamera(userLat, userLng);
      } else {
        try {
          final String encodedPolyline =
              directions!['routes'][0]['overview_polyline']['points']
                  as String;
          dev.log("Encoded polyline: $encodedPolyline", name: "MapTrackingScreen");
          compute(decodePolyline, encodedPolyline).then((points) {
            // Simplify the decoded polyline.
            List<LatLng> simplifiedPoints =
                PolylineSimplifier.simplifyPolyline(points, 10);
            if (mounted) {
              setState(() {
                _polylines = {
                  Polyline(
                    polylineId: const PolylineId('route'),
                    points: simplifiedPoints,
                    color: Colors.blue,
                    width: 4,
                  )
                };
                _isLoading = false;
              });
              _adjustCamera(userLat, userLng);
            }
          }).catchError((error) {
            if (mounted) {
              setState(() {
                _isLoading = false;
              });
              dev.log("Error decoding polyline: $error", name: "MapTrackingScreen");
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text("Error decoding route: $error")),
              );
            }
          });
        } catch (e) {
          if (mounted) {
            setState(() {
              _isLoading = false;
            });
            dev.log("Error processing directions data: $e", name: "MapTrackingScreen");
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

    // Start listening for location updates to update the current location marker.
    _startLocationUpdates();
  }

  Future<void> _startLocationUpdates() async {
    // Use high accuracy updates in the foreground.
    LocationSettings settings = const LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 5, // Update when moved 5 meters.
    );
    _locationSubscription =
        Geolocator.getPositionStream(locationSettings: settings).listen((position) {
      _currentUserLocation = LatLng(position.latitude, position.longitude);
      dev.log("MapTrackingScreen: New user location: (${position.latitude}, ${position.longitude})",
          name: "MapTrackingScreen");
      // Update the marker for current location.
      setState(() {
        _markers.removeWhere(
            (marker) => marker.markerId.value == 'currentLocationMarker');
        _markers.add(
          Marker(
            markerId: const MarkerId('currentLocationMarker'),
            position: _currentUserLocation!,
            infoWindow: const InfoWindow(title: 'Your Location'),
          ),
        );
      });
    });
  }

  Future<void> _adjustCamera(double userLat, double userLng) async {
    final GoogleMapController controller = await _mapController.future;
    if (_destinationLat == null || _destinationLng == null) return;
    final bounds = LatLngBounds(
      southwest: LatLng(min(userLat, _destinationLat!), min(userLng, _destinationLng!)),
      northeast: LatLng(max(userLat, _destinationLat!), max(userLng, _destinationLng!)),
    );
    controller.animateCamera(CameraUpdate.newLatLngBounds(bounds, 50));
  }

  @override
  void dispose() {
    _locationSubscription?.cancel();
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
                    if (_isLoading)
                      const Center(child: CircularProgressIndicator()),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    Text(
                      _etaText,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _distanceText,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: () {
                        Navigator.pushReplacementNamed(context, '/');
                      },
                      child: const Text('End Tracking'),
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