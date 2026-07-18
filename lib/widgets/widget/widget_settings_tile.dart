// lib/widgets/widget/widget_settings_tile.dart
//
// GeoWake home-screen widget — the Settings enable/disable control
// (FEATURES_SPEC §3.6-A). This is the Pro gate surface for the widget: a free
// (or not-yet-loaded) user tapping it is routed through the single ProGate.run
// choke point to the paywall; a Pro user gets a working toggle that turns the
// widget's live state push on/off.
//
// Reactive: wraps MonetizationService.tierListenable so a purchase / rewarded
// day-pass instantly flips the row from locked → enabled with no restart.
// Fail-safe: entitlement is read null-safely and every side-effecting call is
// wrapped — a widget failure never blocks Settings. Every string says "GeoWake".

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:geowake2/services/monetization/monetization_service.dart';
import 'package:geowake2/services/monetization/premium_service.dart';
import 'package:geowake2/services/widget/home_widget_bridge.dart';
import 'package:geowake2/widgets/monetization/pro_gate.dart';

/// Persisted "user wants the widget populated" preference. Independent of
/// entitlement — if Pro lapses we simply stop pushing live state; the flag is
/// remembered so a re-subscribe restores it.
const String kWidgetEnabledPrefKey = 'gw_widget_enabled_v1';

class WidgetSettingsTile extends StatefulWidget {
  const WidgetSettingsTile({super.key});

  @override
  State<WidgetSettingsTile> createState() => _WidgetSettingsTileState();
}

class _WidgetSettingsTileState extends State<WidgetSettingsTile> {
  bool _enabled = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    bool enabled = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      enabled = prefs.getBool(kWidgetEnabledPrefKey) ?? false;
    } catch (_) {/* default off */}
    if (!mounted) return;
    setState(() {
      _enabled = enabled;
      _loading = false;
    });
  }

  Future<void> _persist(bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(kWidgetEnabledPrefKey, value);
    } catch (_) {/* best effort */}
  }

  void _onTapLocked() {
    // Single choke point → paywall, source: widget.
    ProGate.run(
      context,
      allowed: false,
      source: PaywallSource.widget,
      onAllowed: () {}, // never called when allowed == false
    );
  }

  Future<void> _setEnabled(bool value) async {
    setState(() => _enabled = value);
    await _persist(value);
    try {
      if (value) {
        await HomeWidgetBridge.instance.refresh(immediate: true);
      } else {
        await HomeWidgetBridge.instance.clear();
      }
    } catch (_) {/* widget failure never blocks settings */}
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<EntitlementTier>(
      valueListenable: MonetizationService.instance.tierListenable,
      builder: (context, tier, _) {
        // Null-safe entitlement read: null (pre-init) ⇒ locked.
        final canUse =
            MonetizationService.instance.premiumOrNull?.canUseWidget ?? false;

        if (_loading) {
          return const ListTile(
            leading: Icon(Icons.widgets_outlined),
            title: Text('Home-screen widget'),
            subtitle: Text('GeoWake'),
          );
        }

        if (!canUse) {
          // Locked row: a PRO pill + tap → paywall. No working switch.
          return ListTile(
            leading: const Icon(Icons.widgets_outlined),
            title: const Text('Home-screen widget'),
            subtitle: const Text(
              'Arm your next commute in one tap from the home screen.',
            ),
            trailing: const ProBadge(),
            onTap: _onTapLocked,
          );
        }

        // Unlocked: a real toggle.
        return SwitchListTile(
          secondary: const Icon(Icons.widgets_outlined),
          title: const Text('Home-screen widget'),
          subtitle: const Text(
            'Show your next GeoWake commute and arm it in one tap.',
          ),
          value: _enabled,
          onChanged: (v) => _setEnabled(v),
        );
      },
    );
  }
}
