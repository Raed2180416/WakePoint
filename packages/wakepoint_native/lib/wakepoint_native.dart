import 'dart:io' show Platform;
import 'package:flutter/services.dart';

/// Thin Dart wrapper over the `geowake/native` MethodChannel.
/// Safe to call from BOTH the UI isolate and the flutter_background_service
/// background isolate (registered via GeneratedPluginRegistrant on both engines).
class WakepointNative {
  WakepointNative._();
  static const MethodChannel _channel = MethodChannel('geowake/native');

  static Future<bool> acquireWakeLock() async {
    if (!Platform.isAndroid) return false;
    try {
      return (await _channel.invokeMethod<bool>('acquireWakeLock')) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> releaseWakeLock() async {
    if (!Platform.isAndroid) return false;
    try {
      return (await _channel.invokeMethod<bool>('releaseWakeLock')) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> isWakeLockHeld() async {
    if (!Platform.isAndroid) return false;
    try {
      return (await _channel.invokeMethod<bool>('isWakeLockHeld')) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> canUseFullScreenIntent() async {
    if (!Platform.isAndroid) return true;
    try {
      return (await _channel.invokeMethod<bool>('canUseFullScreenIntent')) ??
          true;
    } catch (_) {
      return true;
    }
  }

  /// isNotificationPolicyAccessGranted(): does the app hold DND policy access,
  /// so the alarm channel's setBypassDnd(true) actually takes effect? Unknown
  /// => true (don't nag).
  static Future<bool> isNotificationPolicyAccessGranted() async {
    if (!Platform.isAndroid) return true;
    try {
      return (await _channel
              .invokeMethod<bool>('isNotificationPolicyAccessGranted')) ??
          true;
    } catch (_) {
      return true;
    }
  }

  /// Is Do Not Disturb currently filtering interruptions
  /// (currentInterruptionFilter != ALL)? Unknown => false (treat as DND off).
  static Future<bool> isDndActive() async {
    if (!Platform.isAndroid) return false;
    try {
      return (await _channel.invokeMethod<bool>('isDndActive')) ?? false;
    } catch (_) {
      return false;
    }
  }
}
