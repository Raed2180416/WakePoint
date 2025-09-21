import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Contains predefined routes for testing purposes.
class TestRoutes {
  /// A sample route from Majestic Bus Station heading towards Lalbagh Botanical Garden.
  static const List<LatLng> majesticToLalbagh = [
    LatLng(12.9767, 77.5713), // Start: Majestic
    LatLng(12.9745, 77.5732),
    LatLng(12.9721, 77.5755),
    LatLng(12.9698, 77.5780),
    LatLng(12.9673, 77.5805),
    LatLng(12.9650, 77.5828),
    LatLng(12.9625, 77.5845),
    LatLng(12.9600, 77.5855), // Getting closer...
    LatLng(12.9575, 77.5860),
    LatLng(12.9550, 77.5865), // Almost there...
    LatLng(12.9515, 77.5868), // Destination: Lalbagh Main Gate
  ];
}

