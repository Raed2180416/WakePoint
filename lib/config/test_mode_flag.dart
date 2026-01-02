// lib/config/test_mode_flag.dart
//
// File-based test mode flag that works across isolates.
//
// Problem: `static bool isTestMode` is per-isolate, so changes in the main
// isolate are not visible in the background isolate.
//
// Solution: Use file-based flags that persist to disk and can be read
// by any isolate.

import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// File-based test mode flag for cross-isolate reliability.
///
/// Usage:
/// ```dart
/// // Set test mode
/// await TestModeFlag.setTestMode(true);
///
/// // Check test mode (from any isolate)
/// if (await TestModeFlag.isTestMode()) {
///   // Test-specific behavior
/// }
/// ```
class TestModeFlag {
  static const _flagFile = 'test_mode_flag';
  static String? _cachedPath;

  /// Get the flag file path (cached for performance).
  static Future<String> _getFlagPath() async {
    if (_cachedPath != null) return _cachedPath!;
    final dir = await getApplicationDocumentsDirectory();
    _cachedPath = '${dir.path}/$_flagFile';
    return _cachedPath!;
  }

  /// Set test mode on or off.
  ///
  /// When [value] is true, creates a flag file.
  /// When [value] is false, deletes the flag file.
  static Future<void> setTestMode(bool value) async {
    final path = await _getFlagPath();
    final file = File(path);

    if (value) {
      await file.writeAsString('true');
    } else {
      if (await file.exists()) {
        await file.delete();
      }
    }
  }

  /// Check if test mode is enabled.
  ///
  /// Returns true if the flag file exists.
  static Future<bool> isTestMode() async {
    final path = await _getFlagPath();
    final file = File(path);
    return await file.exists();
  }

  /// Clear the cached path (for testing).
  static void clearCache() {
    _cachedPath = null;
  }
}
