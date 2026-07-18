// lib/widgets/monetization/pro_gate.dart
//
// The SINGLE choke point for every Pro paywall in GeoWake. A grep for
// "ProGate.run" enumerates and audits every gate in the app.
//
// The core never-late alarm and basic share are NEVER routed through here —
// they are free by construction (PremiumService.canUseCoreAlarm and the share
// action carry no entitlement check anywhere).

import 'package:flutter/material.dart';

/// Where a paywall was triggered from — drives which value item the paywall
/// highlights and scrolls to, plus analytics. Add sources as features land.
/// (Deliberately no `smartSnooze`: a wake-before-your-stop alarm must never be
/// delayable, so there is no snooze feature to gate.)
enum PaywallSource {
  drawer,
  recurringAutoArm,
  guardian,
  multiAlarm,
  savedRoutes,
  customSound,
  offline,
  widget,
  wearOs,
  tripStats,
  postArrival,
}

/// The one gate every premium tap goes through.
///
/// [allowed] is the entitlement read, computed by the caller (e.g.
/// `MonetizationService.instance.premiumOrNull?.canUseRecurringAlarms ?? false`)
/// so this widget never imports the entitlement layer. A null/loading/expired
/// entitlement resolves to `false` at the call site ⇒ the paywall shows, never a
/// broken tap.
class ProGate {
  const ProGate._();

  static const String paywallRoute = '/paywall';

  static void run(
    BuildContext context, {
    required bool allowed,
    required PaywallSource source,
    required VoidCallback onAllowed,
  }) {
    if (allowed) {
      onAllowed();
    } else {
      Navigator.of(context).pushNamed(paywallRoute, arguments: source);
    }
  }
}

/// A small "PRO" pill for locked list tiles / buttons.
class ProBadge extends StatelessWidget {
  const ProBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.primary,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        'PRO',
        style: TextStyle(
          color: scheme.onPrimary,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
