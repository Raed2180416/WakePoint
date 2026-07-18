// Minimal web entrypoint that boots straight into the EKF/reachability test
// panel (the "simulation playground web engine"), skipping the app's home flow.
// Build:  flutter build web -t lib/main_playground.dart
// Serve:  (any static server over build/web)
//
// The panel renders no GoogleMap, so it runs on web without a Maps key; the log
// panel surfaces the never-late reachability cone (🛡️ REACH) alongside the EKF
// and alarm events.
import 'package:flutter/material.dart';

import 'dashboard/ekf_test_panel.dart';

void main() {
  runApp(const _PlaygroundApp());
}

class _PlaygroundApp extends StatelessWidget {
  const _PlaygroundApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GeoWake Playground',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: const Scaffold(
        body: SafeArea(
          child: EkfTestPanel(),
        ),
      ),
    );
  }
}
