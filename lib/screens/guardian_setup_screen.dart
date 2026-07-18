// lib/screens/guardian_setup_screen.dart
//
// Guardian mode (Pro) setup — pick a contact + toggle auto-share. Reached only
// through ProGate.run (GuardianSettingsSection), but it also self-guards: a
// non-Pro user who lands here sees the locked state and a paywall CTA, and every
// mutating GuardianService call is Pro-gated underneath (GuardianDenied →
// paywall). Contact entry is manual (name + phone) so no contacts permission /
// package is required.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/monetization/monetization_service.dart';
import '../services/monetization/premium_service.dart';
import '../services/share/guardian_service.dart';
import '../services/share/journey_share_models.dart';
import '../widgets/monetization/pro_gate.dart';

class GuardianSetupScreen extends StatefulWidget {
  const GuardianSetupScreen({super.key});

  @override
  State<GuardianSetupScreen> createState() => _GuardianSetupScreenState();
}

class _GuardianSetupScreenState extends State<GuardianSetupScreen> {
  final _guardian = GuardianService.instance;
  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  GuardianChannel _channel = GuardianChannel.sms;

  bool _loading = true;
  bool _enabled = false;
  GuardianContact? _contact;

  @override
  void initState() {
    super.initState();
    _hydrate();
  }

  Future<void> _hydrate() async {
    final c = await _guardian.getContact();
    final on = await _guardian.isEnabled();
    if (!mounted) return;
    setState(() {
      _contact = c;
      _enabled = on;
      if (c != null) {
        _nameCtrl.text = c.displayName;
        _phoneCtrl.text = c.address;
        _channel = c.channel;
      }
      _loading = false;
    });
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    super.dispose();
  }

  bool get _allowed =>
      MonetizationService.instance.premiumOrNull?.canUseGuardianMode ?? false;

  Future<void> _saveContact() async {
    if (_nameCtrl.text.trim().isEmpty || _phoneCtrl.text.trim().isEmpty) {
      _snack('Add a name and phone number');
      return;
    }
    try {
      final c = await _guardian.setContact(
        displayName: _nameCtrl.text,
        channel: _channel,
        address: _phoneCtrl.text,
      );
      if (!mounted) return;
      setState(() => _contact = c);
      _snack('Guardian contact saved');
    } on GuardianDenied {
      _toPaywall();
    } catch (_) {
      _snack('Couldn\'t save just now');
    }
  }

  Future<void> _toggle(bool v) async {
    try {
      await _guardian.setEnabled(v);
      if (!mounted) return;
      setState(() => _enabled = v);
    } on GuardianDenied catch (e) {
      if (v && _contact != null) {
        _snack(e.message);
      } else {
        _toPaywall();
      }
    } catch (_) {
      _snack('Couldn\'t update Guardian mode');
    }
  }

  void _toPaywall() {
    Navigator.of(context).pushNamed(
      ProGate.paywallRoute,
      arguments: PaywallSource.guardian,
    );
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Guardian mode')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ValueListenableBuilder<EntitlementTier>(
              valueListenable: MonetizationService.instance.tierListenable,
              builder: (context, _, __) {
                return ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    _intro(theme),
                    const SizedBox(height: 20),
                    if (!_allowed) _lockedCard(theme),
                    if (_allowed) ..._proBody(theme),
                  ],
                );
              },
            ),
    );
  }

  Widget _intro(ThemeData theme) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.shield_outlined, color: theme.colorScheme.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Let someone you trust follow your commute and get an "arrived '
                'safely" note when GeoWake wakes you.',
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ]),
        ],
      );

  Widget _lockedCard(ThemeData theme) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: const [
                ProBadge(),
                SizedBox(width: 10),
                Text('Guardian mode is a GeoWake Pro feature'),
              ]),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _toPaywall,
                child: const Text('Unlock GeoWake Pro'),
              ),
            ],
          ),
        ),
      );

  List<Widget> _proBody(ThemeData theme) => [
        Text('Guardian contact', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        TextField(
          controller: _nameCtrl,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Name',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _phoneCtrl,
          keyboardType: TextInputType.phone,
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9+ ]')),
          ],
          decoration: const InputDecoration(
            labelText: 'Phone number',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        SegmentedButton<GuardianChannel>(
          segments: const [
            ButtonSegment(
                value: GuardianChannel.sms,
                icon: Icon(Icons.sms_outlined),
                label: Text('SMS')),
            ButtonSegment(
                value: GuardianChannel.whatsapp,
                icon: Icon(Icons.chat_outlined),
                label: Text('WhatsApp')),
          ],
          selected: {_channel},
          onSelectionChanged: (s) => setState(() => _channel = s.first),
        ),
        const SizedBox(height: 12),
        FilledButton.tonal(
          onPressed: _saveContact,
          child: const Text('Save contact'),
        ),
        const Divider(height: 40),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Auto-share every commute'),
          subtitle: const Text(
              'Shares a live link on arm and sends "arrived safely" on wake'),
          value: _enabled,
          onChanged: _contact == null ? null : _toggle,
        ),
        if (_contact == null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('Save a contact first',
                style: theme.textTheme.bodySmall),
          ),
      ];
}
