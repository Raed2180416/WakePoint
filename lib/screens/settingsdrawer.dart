// lib/screens/settingsdrawer.dart

import 'package:flutter/material.dart';
import '../main.dart';
import '../widgets/monetization/pro_gate.dart';
import 'package:geowake2/services/tracking_state_store.dart';

// --- STEP 1: ADD THIS IMPORT ---
// This line tells our settings drawer that the RingtonesScreen exists and where to find it.
import 'package:geowake2/screens/ringtones_screen.dart';

class SettingsDrawer extends StatelessWidget {
  const SettingsDrawer({
    super.key,
    required this.metroModeEnabled,
    this.isMetroTimeMode = false,
  });

  final bool metroModeEnabled;
  final bool isMetroTimeMode;

  @override
  Widget build(BuildContext context) {
    final appState = context.findAncestorStateOfType<MyAppState>();
    final isDarkMode = appState?.isDarkMode ?? false;

    return Drawer(
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            const DrawerHeader(
              decoration: BoxDecoration(color: Colors.deepPurple),
              child: Text(
                'Settings',
                style: TextStyle(
                  fontFamily: 'Pacifico', // Using fontFamily for consistency
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            ListTile(
              leading: Icon(
                isDarkMode ? Icons.wb_sunny : Icons.nightlight_round,
              ),
              title: Text(isDarkMode ? 'Light Mode' : 'Dark Mode'),
              onTap: () {
                appState?.toggleTheme();
                Navigator.of(context).pop();
              },
            ),
            _PreboardingToggleTile(
              metroModeEnabled: metroModeEnabled,
              isMetroTimeMode: isMetroTimeMode,
            ),
            ListTile(
              leading: const Icon(Icons.alarm),
              title: const Text('Alarm Ringtones'),
              // --- STEP 2: UPDATE THIS onTap FUNCTION ---
              onTap: () {
                // This closes the drawer before navigating to the new screen
                // for a smoother user experience.
                Navigator.of(context).pop();

                // This is the command that pushes the RingtonesScreen onto the view.
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (context) => const RingtonesScreen(),
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.star),
              title: const Text('Go Premium'),
              onTap: () {
                Navigator.of(context).pushNamed(
                  '/paywall',
                  arguments: PaywallSource.drawer,
                );
              },
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('Close'),
              onTap: () {
                Navigator.of(context).pop();
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _PreboardingToggleTile extends StatefulWidget {
  const _PreboardingToggleTile({
    required this.metroModeEnabled,
    required this.isMetroTimeMode,
  });

  final bool metroModeEnabled;
  final bool isMetroTimeMode;

  @override
  State<_PreboardingToggleTile> createState() => _PreboardingToggleTileState();
}

class _PreboardingToggleTileState extends State<_PreboardingToggleTile> {
  bool _enabled = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final v =
        widget.isMetroTimeMode
            ? await TrackingStateStore.destinationOnlyMetroTimeEnabled()
            : await TrackingStateStore.preboardingEnabled();
    if (!mounted) return;
    setState(() {
      _enabled = v;
    });
  }

  @override
  Widget build(BuildContext context) {
    final title =
        widget.isMetroTimeMode
            ? 'Fire only destination alarm'
            : 'Preboarding alarms';
    final subtitle =
        widget.metroModeEnabled
            ? (widget.isMetroTimeMode
                ? 'Suppress leg alarms; only destination will fire'
                : 'Notify before boarding metro')
            : 'Enable Metro Mode to use this';

    return SwitchListTile(
      secondary: const Icon(Icons.directions_subway),
      title: Text(title),
      subtitle: Text(subtitle),
      value: _enabled,
      onChanged:
          widget.metroModeEnabled
              ? (v) {
                setState(() {
                  _enabled = v;
                });
                if (widget.isMetroTimeMode) {
                  TrackingStateStore.setDestinationOnlyMetroTimeEnabled(v);
                } else {
                  TrackingStateStore.setPreboardingEnabled(v);
                }
              }
              : null,
    );
  }
}
