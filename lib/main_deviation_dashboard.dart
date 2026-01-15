/// Entry point for the deviation simulation dashboard.
///
/// Run with: flutter run -d chrome -t lib/main_deviation_dashboard.dart
library;

import 'package:flutter/material.dart';
import 'dashboard/deviation_dashboard.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const DeviationDashboardApp());
}
