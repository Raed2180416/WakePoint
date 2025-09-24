import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'dart:developer' as dev;

class PreloadMapScreen extends StatefulWidget {
  final Map<String, dynamic> arguments;
  const PreloadMapScreen({Key? key, required this.arguments}) : super(key: key);

  @override
  State<PreloadMapScreen> createState() => _PreloadMapScreenState();
}

class _PreloadMapScreenState extends State<PreloadMapScreen> {
  final Completer<GoogleMapController> _controller = Completer();
  bool _isMapReady = false;
  Timer? _handoffTimer;

  @override
  Widget build(BuildContext context) {
    dev.log("PreloadMapScreen arguments: ${widget.arguments.toString()}", name: "PreloadMapScreen");
    return Scaffold(
      body: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: CameraPosition(
              target: LatLng(
                (widget.arguments['lat'] as num?)?.toDouble() ?? 37.422,
                (widget.arguments['lng'] as num?)?.toDouble() ?? -122.084,
              ),
              zoom: 14,
            ),
            onMapCreated: (controller) {
              if (!_controller.isCompleted) {
                _controller.complete(controller);
              }
              if (!_isMapReady) {
                if (!mounted) return;
                setState(() => _isMapReady = true);
                dev.log("PreloadMapScreen: Map is ready.", name: "PreloadMapScreen");
                _handoffTimer = Timer(const Duration(milliseconds: 700), () async {
                  if (!mounted) return;
                  Navigator.pushReplacementNamed(context, '/mapTracking', arguments: widget.arguments);
                });
              }
            },
            myLocationEnabled: false,
            zoomControlsEnabled: false,
          ),
          if (!_isMapReady)
            const Center(child: CircularProgressIndicator()),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _handoffTimer?.cancel();
    super.dispose();
  }
}
