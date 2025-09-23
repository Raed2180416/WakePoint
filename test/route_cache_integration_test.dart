import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/api_client.dart';
import 'package:geowake2/services/direction_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('DirectionService stores and reuses cached directions', () async {
    ApiClient.testMode = true;
    final ds = DirectionService();

    // Call 1 - should populate cache
    final r1 = await ds.getDirections(
      12.0, 77.0, 12.5, 77.5,
      isDistanceMode: true,
      threshold: 5.0,
      transitMode: false,
    );
    expect(r1['status'] ?? 'OK', 'OK');

    // Call 2 - should be served from in-memory/RouteCache path (no observable side-effect except fast return)
    final start = DateTime.now();
    final r2 = await ds.getDirections(
      12.0, 77.0, 12.5, 77.5,
      isDistanceMode: true,
      threshold: 5.0,
      transitMode: false,
    );
    final elapsedMs = DateTime.now().difference(start).inMilliseconds;

    expect(r2['status'] ?? 'OK', 'OK');
    // Heuristic: cached path returns very quickly in test mode
    expect(elapsedMs < 50, true);
  });
}
