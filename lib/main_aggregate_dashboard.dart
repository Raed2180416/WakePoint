/// Entry point for the buyer-facing aggregate mobility data dashboard.
///
/// Run with:
///   flutter run -d chrome -t lib/main_aggregate_dashboard.dart --web-port 8081
library;

import 'package:flutter/material.dart';
import 'dashboard/aggregate_data_dashboard.dart' as dashboard;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const dashboard.AggregateDashboardApp());
}
