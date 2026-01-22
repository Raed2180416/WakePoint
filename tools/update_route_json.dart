import 'dart:convert';
import 'dart:io';
import 'dart:math';

// Simple polyline decoder
List<List<double>> decodePolyline(String encoded) {
  List<List<double>> poly = [];
  int index = 0, len = encoded.length;
  int lat = 0, lng = 0;

  while (index < len) {
    int b, shift = 0, result = 0;
    do {
      b = encoded.codeUnitAt(index++) - 63;
      result |= (b & 0x1f) << shift;
      shift += 5;
    } while (b >= 0x20);
    int dlat = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
    lat += dlat;

    shift = 0;
    result = 0;
    do {
      b = encoded.codeUnitAt(index++) - 63;
      result |= (b & 0x1f) << shift;
      shift += 5;
    } while (b >= 0x20);
    int dlng = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
    lng += dlng;

    poly.add([lat / 1E5, lng / 1E5]);
  }
  return poly;
}

// Simple Haversine implementation
double calculateDistance(double lat1, double lon1, double lat2, double lon2) {
  var p = 0.017453292519943295;
  var c = cos;
  var a =
      0.5 -
      c((lat2 - lat1) * p) / 2 +
      c(lat1 * p) * c(lat2 * p) * (1 - c((lon2 - lon1) * p)) / 2;
  return 12742 * asin(sqrt(a)) * 1000; // 2 * R * asin... R = 6371 km
}

void main() async {
  try {
    // 1. Read captured route log
    final logFile = File('route_log_captured_utf8.json');
    if (!await logFile.exists()) {
      print('Error: route_log_captured_utf8.json not found');
      exit(1);
    }
    final logJson = jsonDecode(await logFile.readAsString());

    // Extract overview polyline
    final directions = logJson['directions'];
    final route = directions['routes'][0];
    final overviewPolyline = route['overview_polyline']['points'];

    if (overviewPolyline == null) {
      print('Error: No overview polyline found in log');
      exit(1);
    }

    print('Found overview polyline length: ${overviewPolyline.length}');

    // Decode
    final points = decodePolyline(overviewPolyline);
    print('Decoded ${points.length} points');

    // 2. Read bengaluru_metro_routes.json
    final routesFile = File(
      'assets/ekf_test_routes/bengaluru_metro_routes.json',
    );
    if (!await routesFile.exists()) {
      print('Error: bengaluru_metro_routes.json not found');
      exit(1);
    }
    final routesData = jsonDecode(await routesFile.readAsString());

    // 3. Update nallur_halli_to_vijayanagar
    final routes = routesData['routes'] as List;
    final targetRoute = routes.firstWhere(
      (r) => r['id'] == 'nallur_halli_to_vijayanagar',
      orElse: () => null,
    );

    if (targetRoute == null) {
      print('Error: Target route not found in JSON');
      exit(1);
    }

    // Calculate cumulative meters for the new polyline
    // Simple logic: distance between points
    List<double> cumulativeMeters = [0.0];
    double totalDist = 0;

    for (int i = 0; i < points.length - 1; i++) {
      final p1 = points[i];
      final p2 = points[i + 1];
      final dist = calculateDistance(p1[0], p1[1], p2[0], p2[1]);
      totalDist += dist;
      cumulativeMeters.add(totalDist);
    }

    // Update fields
    targetRoute['polyline_points'] = points;
    targetRoute['cumulative_meters'] = cumulativeMeters;
    targetRoute['total_meters'] = totalDist;
    targetRoute['name'] =
        "Nallur Halli to Vijayanagar (Ground Truth from Directions API)";

    print('Updated route. Total distance: ${totalDist.toStringAsFixed(1)}m');

    // 4. Write back
    await routesFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(routesData),
    );
    print('Successfully updated bengaluru_metro_routes.json');
  } catch (e, st) {
    print('Error: $e\n$st');
    exit(1);
  }
}
