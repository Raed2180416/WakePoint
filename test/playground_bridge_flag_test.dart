import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/config/playground_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Playground bridge is disabled under flutter test environment', () {
    // detectFlutterTest() should force disable to keep tests hermetic
    expect(PlaygroundBridgeConfig.enabled, isFalse);
  });
}
