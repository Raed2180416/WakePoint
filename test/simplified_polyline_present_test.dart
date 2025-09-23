import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/api_client.dart';
import 'package:geowake2/services/direction_service.dart';
import 'log_helper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('DirectionService injects simplified_polyline into directions', () async {
    logSection('DirectionService: simplified_polyline injection');
    ApiClient.testMode = true;
    final ds = DirectionService();
    final directions = await ds.getDirections(
      12.0, 77.0, 12.5, 77.5,
      isDistanceMode: true,
      threshold: 5.0,
      transitMode: false,
      forceRefresh: true,
    );

    final routes = directions['routes'] as List<dynamic>;
    expect(routes.isNotEmpty, true);
    final route = routes.first as Map<String, dynamic>;
    expect(route.containsKey('simplified_polyline'), true);
    logPass('simplified_polyline present in response');
    expect(route['simplified_polyline'], isA<String>());
  });
}
