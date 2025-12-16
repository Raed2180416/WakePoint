bool detectFlutterTest() {
  return const bool.fromEnvironment('FLUTTER_TEST', defaultValue: false);
}
