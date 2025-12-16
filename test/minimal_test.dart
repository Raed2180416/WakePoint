import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/trackingservice.dart';

void main() {
  test('Minimal compilation check', () {
    final svc = TrackingService();
    expect(svc, isNotNull);
  });
}
