// lib/screens/mobility_data_consent_screen.dart
//
// GeoWake — standalone DPDP Rule-3 consent screen for the opt-in aggregate
// mobility data surface (DATA_SURFACE_SPEC §2.11 copy, §2.10 service).
//
// Registered at route `/dataConsent`. The class is [DataSharingConsentScreen]
// (the route target named in FEATURES_SPEC §2.1); it drives
// [MobilityConsentService] (persistence key `gw_mobility_consent_v1`).
//
// This screen never gates the alarm and never touches core state. It only reads/
// writes the dedicated consent record and, on withdrawal, triggers on-device
// erasure via the pipeline's wired hook. Default is OFF; the switch cannot be
// turned on without the 18+ self-attestation.

import 'package:flutter/material.dart';

import 'package:geowake2/services/data_asset/data_asset_pipeline.dart';
import 'package:geowake2/services/data_asset/mobility_consent_copy.dart';
import 'package:geowake2/services/data_asset/mobility_consent_service.dart';

class DataSharingConsentScreen extends StatefulWidget {
  const DataSharingConsentScreen({super.key});

  @override
  State<DataSharingConsentScreen> createState() =>
      _DataSharingConsentScreenState();
}

class _DataSharingConsentScreenState extends State<DataSharingConsentScreen> {
  MobilityConsentService? _consent;
  bool _sharing = false;
  bool _ageConfirmed = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _consent = DataAssetPipeline.instance.consentOrNull;
    _sharing = _consent?.isSharingEnabled ?? false;
    // If already enabled, the age gate has already been satisfied.
    _ageConfirmed = _sharing;
  }

  Future<void> _onToggle(bool wantOn) async {
    final consent = _consent;
    if (consent == null || _busy) return;
    setState(() => _busy = true);
    try {
      if (wantOn) {
        if (!_ageConfirmed) {
          _snack(MobilityConsentCopy.ageConfirmLabel);
          return;
        }
        await consent.grant();
        if (mounted) _snack(MobilityConsentCopy.enabledSnack);
      } else {
        await consent.withdraw();
        if (mounted) _snack(MobilityConsentCopy.withdrawnSnack);
      }
    } catch (_) {
      // Fail-safe: never crash the screen on a consent write.
    } finally {
      if (mounted) {
        setState(() {
          _sharing = consent.isSharingEnabled;
          _busy = false;
        });
      }
    }
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final unavailable = _consent == null;
    return Scaffold(
      appBar: AppBar(title: const Text('Anonymous trip stats')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          children: [
            Text(MobilityConsentCopy.title, style: theme.textTheme.headlineSmall),
            const SizedBox(height: 16),
            _section(theme, 'What GeoWake shares', MobilityConsentCopy.dataItemised),
            _section(theme, 'Why', MobilityConsentCopy.purpose),
            _section(theme, 'Your guarantees', MobilityConsentCopy.guarantees),
            _section(theme, 'How we protect it', MobilityConsentCopy.methodDisclosure),
            const Divider(height: 32),
            CheckboxListTile(
              value: _ageConfirmed,
              onChanged: (unavailable || _sharing || _busy)
                  ? null
                  : (v) => setState(() => _ageConfirmed = v ?? false),
              title: const Text(MobilityConsentCopy.ageConfirmLabel),
              subtitle: const Text(MobilityConsentCopy.ageLine),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
            ),
            SwitchListTile(
              value: _sharing,
              onChanged: (unavailable || _busy) ? null : _onToggle,
              title: const Text(MobilityConsentCopy.toggleLabel),
              subtitle: Text(
                _sharing
                    ? MobilityConsentCopy.withdrawLine
                    : (unavailable
                        ? 'GeoWake is still starting up — please try again in a moment.'
                        : 'Off by default. Turn on only if you are happy to help.'),
              ),
              contentPadding: EdgeInsets.zero,
            ),
            const Divider(height: 32),
            Text(MobilityConsentCopy.grievanceContactPlaceholder,
                style: theme.textTheme.bodySmall),
            const SizedBox(height: 8),
            Text(MobilityConsentCopy.dataProtectionBoardPlaceholder,
                style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }

  Widget _section(ThemeData theme, String heading, String body) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(heading, style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(body, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}
