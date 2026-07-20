// lib/screens/settingsdrawer.dart

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../main.dart';
import '../widgets/monetization/pro_gate.dart';
import '../services/monetization/monetization_service.dart';
import 'package:geowake2/services/tracking_state_store.dart';

// --- STEP 1: ADD THIS IMPORT ---
// This line tells our settings drawer that the RingtonesScreen exists and where to find it.
import 'package:geowake2/screens/ringtones_screen.dart';
import 'package:geowake2/screens/friends_rides_screen.dart';
import 'package:geowake2/screens/report_problem_screen.dart';

/// Founder: replace `YOUR_HANDLE` with your real Buy Me a Coffee handle. Until
/// then the tile shows a hint instead of opening the wrong page (so a supporter
/// never funds someone else's account).
const String kBuyMeACoffeeUrl = 'https://www.buymeacoffee.com/YOUR_HANDLE';

/// Open the support link in an external browser. Captures the messenger before
/// the await so no BuildContext is used across the async gap.
Future<void> _openBuyMeACoffee(BuildContext context) async {
  final messenger = ScaffoldMessenger.of(context);
  Navigator.of(context).pop(); // close the drawer first
  if (kBuyMeACoffeeUrl.contains('YOUR_HANDLE')) {
    messenger.showSnackBar(const SnackBar(
      content: Text('Set your Buy Me a Coffee link (kBuyMeACoffeeUrl)'),
    ));
    return;
  }
  var ok = false;
  try {
    ok = await launchUrl(
      Uri.parse(kBuyMeACoffeeUrl),
      mode: LaunchMode.externalApplication,
    );
  } catch (_) {/* fall through to the failure snackbar */}
  if (!ok) {
    messenger.showSnackBar(const SnackBar(
      content: Text("Couldn't open the link"),
    ));
  }
}

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
              subtitle: const Text('Custom tones (the default alarm is free)'),
              // Custom ringtones are a Pro feature. The core DEFAULT alarm sound
              // stays free — only the custom-tone picker is gated. Free users get
              // the paywall; Pro users get the picker.
              trailing:
                  (MonetizationService.instance.premiumOrNull?.isPro ?? false)
                      ? null
                      : const ProBadge(),
              onTap: () {
                // Close the drawer before showing the picker or the paywall.
                Navigator.of(context).pop();
                ProGate.run(
                  context,
                  allowed: MonetizationService
                          .instance.premiumOrNull?.canUseCustomAlarmSounds ??
                      false,
                  source: PaywallSource.customSound,
                  onAllowed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => const RingtonesScreen(),
                    ),
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.group_outlined),
              title: const Text("Friends' rides"),
              onTap: () {
                Navigator.of(context).pop(); // close the drawer
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (context) => const FriendsRidesScreen(),
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
            ListTile(
              leading: const Icon(Icons.favorite_border),
              title: const Text('Guardian mode'),
              trailing:
                  (MonetizationService.instance.premiumOrNull?.isPro ?? false)
                      ? null
                      : const ProBadge(),
              onTap: () {
                Navigator.of(context).pop();
                ProGate.run(
                  context,
                  allowed: MonetizationService
                          .instance.premiumOrNull?.canUseGuardianMode ??
                      false,
                  source: PaywallSource.guardian,
                  onAllowed: () =>
                      Navigator.of(context).pushNamed('/guardian'),
                );
              },
            ),
            // Separate, purpose-specific consent (NOT Pro) — default-OFF, opt-in.
            ListTile(
              leading: const Icon(Icons.privacy_tip_outlined),
              title: const Text('Anonymous data sharing'),
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).pushNamed('/dataConsent');
              },
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.bug_report_outlined),
              title: const Text('Report a problem'),
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (context) => const ReportProblemScreen(),
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.coffee_outlined),
              title: const Text('Buy me a coffee'),
              subtitle: const Text('Support GeoWake — keeps it ad-light'),
              onTap: () => _openBuyMeACoffee(context),
            ),
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
