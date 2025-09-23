import 'dart:async';
import 'dart:io';
import 'package:hive/hive.dart';

// Runs before any tests. Initializes Hive with a temp directory so boxes open in tests.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  final tmpDir = await Directory.systemTemp.createTemp('geowake2_test_hive_');
  Hive.init(tmpDir.path);
  try {
    await testMain();
  } finally {
    await Hive.close();
    try {
      await tmpDir.delete(recursive: true);
    } catch (_) {}
  }
}
