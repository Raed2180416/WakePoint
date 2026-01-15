import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:vibration/vibration.dart';

import '../config/platform_test_flag_stub.dart'
    if (dart.library.io) '../config/platform_test_flag_io.dart';

class AlarmHaptics {
  static const MethodChannel _channel = MethodChannel('geowake/alarm_haptics');

  static bool _active = false;
  static bool _nativeAvailable = false;

  static Future<void> start({List<int>? pattern}) async {
    if (detectFlutterTest()) return;

    _active = true;
    _nativeAvailable = false;

    // Prefer native Android implementation (uses alarm vibration attributes).
    try {
      // Proactively stop any existing vibration so a subsequent start
      // reliably re-arms the motor on newer Android versions.
      try {
        await _channel.invokeMethod<void>('stop');
      } catch (_) {}

      await _channel.invokeMethod<void>('start', {
        if (pattern != null) 'pattern': pattern,
      });
      _nativeAvailable = true;
      return;
    } catch (_) {
      // Fall back to vibration plugin.
    }

    try {
      final hasVibrator = await Vibration.hasVibrator();
      if (hasVibrator != true) {
        _active = false;
        return;
      }

      // Ensure we restart vibration cleanly.
      try {
        await Vibration.cancel();
        await Future.delayed(const Duration(milliseconds: 20));
      } catch (_) {}

      await Vibration.vibrate(
        pattern: pattern ?? const [0, 500, 250, 500, 250, 1000, 500],
        repeat: 0,
      );
    } catch (_) {
      _active = false;
    }
  }

  static Future<void> stop() async {
    _active = false;
    _nativeAvailable = false;
    if (detectFlutterTest()) return;

    // Prefer native Android cancellation.
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {}

    // Also attempt plugin cancel as fallback.
    try {
      await Vibration.cancel();
      await Future.delayed(const Duration(milliseconds: 50));
      await Vibration.cancel();
    } catch (_) {}
  }

  @visibleForTesting
  static bool get isActiveForTests => _active;

  /// True when the native Android vibration implementation (with alarm usage)
  /// is available and was successfully invoked.
  static bool get isUsingNativeForAndroid => _nativeAvailable;
}
