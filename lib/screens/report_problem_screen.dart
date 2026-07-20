// lib/screens/report_problem_screen.dart
//
// "Report a problem" — a user-initiated diagnostics report. The user types what
// went wrong, PREVIEWS the exact text that will be sent (app version + coarse
// device info + recent PII-free telemetry), and sends it via the OS share sheet
// / their email app. Nothing is ever uploaded silently — the user chooses the
// target and hits send. This never touches the arm → track → alarm spine.

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../services/telemetry/telemetry_report_builder.dart';

class ReportProblemScreen extends StatefulWidget {
  const ReportProblemScreen({super.key, this.crashedLastSession = false});

  /// When true the report is framed as a crash report and pre-notes it.
  final bool crashedLastSession;

  @override
  State<ReportProblemScreen> createState() => _ReportProblemScreenState();
}

class _ReportProblemScreenState extends State<ReportProblemScreen> {
  final _note = TextEditingController();
  String _diagnostics = 'Gathering diagnostics…';

  @override
  void initState() {
    super.initState();
    _loadPreview();
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _loadPreview() async {
    // Preview shows the diagnostics block only; the user's typed note is
    // prepended at send time (they already know what they wrote).
    final text = await TelemetryReportBuilder.build(
      crashedLastSession: widget.crashedLastSession,
    );
    if (!mounted) return;
    setState(() => _diagnostics = text);
  }

  Future<void> _send() async {
    final text = await TelemetryReportBuilder.build(
      userNote: _note.text,
      crashedLastSession: widget.crashedLastSession,
    );
    await Share.share(text, subject: 'GeoWake diagnostics');
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Report a problem')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Tell us what went wrong. We attach the app version, your device '
                'model, and recent diagnostic events — no location and no personal '
                'data. You choose where to send it; nothing is sent automatically.',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _note,
                minLines: 3,
                maxLines: 5,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: "e.g. the alarm didn't go off near my stop…",
                ),
              ),
              const SizedBox(height: 16),
              Text('What gets sent',
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 6),
              Expanded(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      _diagnostics,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _send,
                icon: const Icon(Icons.send),
                label: const Text('Send report'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
