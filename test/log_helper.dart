// Lightweight logging helpers for tests
void logSection(String title) {
  print("\n===== $title =====");
}

void logStep(String message) {
  print("➡️  $message");
}

void logInfo(String message) {
  print("ℹ️  $message");
}

void logPass(String message) {
  print("✅ $message");
}

void logWarn(String message) {
  print("⚠️  $message");
}
