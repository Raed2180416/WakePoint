import 'dart:convert';
import 'dart:io';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geowake2/services/direction_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Fetch Route JSON', () async {
    final service = DirectionService();

    // Coordinates
    // Sandal Soap Factory Metro Station: 13.014695, 77.555230
    // Whitefield Metro Station: 12.969634, 77.749717

    final origin = LatLng(13.014695, 77.555230);
    final destination = LatLng(12.969634, 77.749717);

    print('Fetching directions...');
    try {
      final result = await service.getDirections(
        origin.latitude,
        origin.longitude,
        destination.latitude,
        destination.longitude,
        isDistanceMode: false,
        threshold: 50,
        transitMode: true,
        preferMetroEvenIfClosed: true,
      );

      if (result['status'] != 'OK') {
        fail('Result status not OK: ${result['status']}');
      }

      final routes = result['routes'] as List?;
      if (routes == null || routes.isEmpty) {
        fail('No routes found in response.');
      }

      final route = routes[0];
      final legs = route['legs'] as List;
      var duration = "?";
      var distance = "?";

      if (legs.isNotEmpty) {
        final leg = legs[0];
        duration = leg['duration']['text'] ?? "?";
        distance = leg['distance']['text'] ?? "?";
      }

      print('Got directions: $distance, $duration');

      // Extract overview polyline
      // Check if overview_polyline exists
      if (route['overview_polyline'] == null) {
        fail('No overview_polyline in response');
      }
      final overviewPolyline = route['overview_polyline']['points'];

      // Construct a simple JSON
      final map = {
        'overview_polyline': overviewPolyline,
        'legs': legs,
        'totalDistance': distance,
        'totalDuration': duration,
      };

      final file = File('docs/Sandalsoap-whitefield/route_ground_truth.json');
      if (!file.parent.existsSync()) {
        file.parent.createSync(recursive: true);
      }
      await file.writeAsString(jsonEncode(map));
      print('Saved route to ${file.absolute.path}');

      if (!file.existsSync()) {
        fail('File failed to write at ${file.path}');
      } else {
        print('File verified at ${file.path}');
      }
    } catch (e, s) {
      fail('Exception caught: $e\n$s');
    }
  });
}
