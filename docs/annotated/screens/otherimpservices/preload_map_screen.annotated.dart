// docs/annotated/screens/otherimpservices/preload_map_screen.annotated.dart
// Annotated copy of lib/screens/otherimpservices/preload_map_screen.dart
// Purpose: Explain the lightweight pre-loader that initializes a Google Map
// before transitioning into the main MapTracking screen. Docs-only file.

import 'dart:async'; // Provides Completer and Future utilities.
import 'package:flutter/material.dart'; // UI scaffolding and widgets.
import 'package:google_maps_flutter/google_maps_flutter.dart'; // Google Map widget and LatLng.
import 'dart:developer' as dev; // Structured logging for diagnostics.

class PreloadMapScreen extends StatefulWidget {
  final Map<String, dynamic> arguments; // Route arguments passed from HomeScreen.
  const PreloadMapScreen({Key? key, required this.arguments}) : super(key: key);

  @override
  State<PreloadMapScreen> createState() => _PreloadMapScreenState(); // Create state instance.
}

class _PreloadMapScreenState extends State<PreloadMapScreen> {
  final Completer<GoogleMapController> _controller = Completer(); // Will hold map controller when ready.
  bool _isMapReady = false; // Tracks when onMapCreated fires to proceed.

  @override
  Widget build(BuildContext context) {
    dev.log("PreloadMapScreen arguments: ${widget.arguments.toString()}", name: "PreloadMapScreen");
    return Scaffold(
      body: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: CameraPosition(
              target: LatLng(
                widget.arguments['lat'] ?? 37.422, // Default coordinates if missing.
                widget.arguments['lng'] ?? -122.084,
              ),
              zoom: 14,
            ),
            onMapCreated: (controller) {
              if (!_controller.isCompleted) {
                _controller.complete(controller); // Resolve controller future once.
              }
              if (!_isMapReady) {
                setState(() {
                  _isMapReady = true; // Mark ready to proceed.
                });
                dev.log("PreloadMapScreen: Map is ready.", name: "PreloadMapScreen");
                // Small delay to allow map to render before navigation handoff.
                Future.delayed(const Duration(milliseconds: 700), () {
                  Navigator.pushReplacementNamed(context, '/mapTracking', arguments: widget.arguments);
                });
              }
            },
            myLocationEnabled: false, // No need for user location in preload view.
            zoomControlsEnabled: false, // Clean presentation.
          ),
          if (!_isMapReady)
            const Center(child: CircularProgressIndicator()), // Simple loading indicator.
        ],
      ),
    );
  }
}

// Post-block summary:
// - Preloads a Google Map with the destination coordinates to warm up rendering.
// - Once the map is created, waits 700ms and navigates to '/mapTracking', replacing itself.
// - Shows a spinner overlay while waiting; no user interaction required here.

// End-of-file summary:
// This screen minimizes perceived latency by setting up the map pipeline early,
// so the main MapTracking screen can appear immediately responsive. It keeps
// responsibilities tight: initialize, briefly display, and hand off.
