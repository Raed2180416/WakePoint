/// Entry point for the unified end-to-end testing dashboard.
///
/// Combines simulation (send) and monitoring (receive) capabilities into
/// a single testing interface.
///
/// Run with: flutter run -d chrome -t lib/main_unified_dashboard.dart --web-port 3000
library;

import 'package:flutter/material.dart';
import 'dashboard/unified_dashboard.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const UnifiedDashboardApp());
}
