import 'dart:io';

bool detectFlutterTest() {
  if (const bool.fromEnvironment('FLUTTER_TEST', defaultValue: false)) {
    return true;
  }
  final flag = Platform.environment['FLUTTER_TEST'];
  if (flag == null) return false;
  return flag.toLowerCase() == 'true';
}
