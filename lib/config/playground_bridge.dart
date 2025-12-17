import 'package:flutter/foundation.dart';

import 'platform_test_flag_stub.dart'
    if (dart.library.io) 'platform_test_flag_io.dart';

/// Controls whether the simulation/playground bridge is active and
/// what relay endpoint should be used for WebSocket mirroring.
class PlaygroundBridgeConfig {
  /// Toggle to force-enable or disable the bridge in non-debug builds.
  /// Defaults to disabled so release builds don't attempt localhost WebSocket
  /// connections (which can stall startup if no relay is present).
  static const bool _bridgeEnabledFlag = bool.fromEnvironment(
    'PLAYGROUND_BRIDGE_ENABLED',
    defaultValue: false,
  );

  static const bool _bridgeDisabledFlag = bool.fromEnvironment(
    'PLAYGROUND_BRIDGE_DISABLED',
    defaultValue: false,
  );

  /// Flutter defines FLUTTER_TEST=true when invoking `flutter test`.
  /// Disable the bridge automatically in that environment so unit tests
  /// remain hermetic without needing extra dart-defines.
  static final bool _isFlutterTest = detectFlutterTest();

  /// Relay endpoint used by both the device and the dashboard.
  static const String relayUrl = String.fromEnvironment(
    'PLAYGROUND_RELAY_URL',
    defaultValue: 'ws://127.0.0.1:8081',
  );

  /// Whether the bridge is allowed to connect in the current build.
  static bool get enabled {
    if (_isFlutterTest) return false;
    if (_bridgeDisabledFlag) return false;
    if (_bridgeEnabledFlag) return true;
    return kDebugMode || kProfileMode;
  }
}
