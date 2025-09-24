// docs/annotated/screens/alarm_fullscreen.annotated.dart
// Annotated copy of lib/screens/alarm_fullscreen.dart
// Purpose: Explain every line, with post-block and EOF summaries. Docs-only.

import 'package:flutter/material.dart'; // Core UI toolkit.
import 'package:geowake2/services/alarm_player.dart'; // Controls alarm audio playback.
import 'package:geowake2/services/trackingservice.dart'; // Allows ending tracking from the alarm screen.

// A full-screen alarm UI shown when an alarm triggers during tracking.
class AlarmFullscreen extends StatelessWidget {
  final String title; // Title text for the alarm (e.g., Stop reached)
  final String body; // Detailed message providing context.
  final bool allowContinueTracking; // If true, show Stop Alarm (keep tracking). Otherwise only End Tracking.

  const AlarmFullscreen({
    super.key,
    required this.title,
    required this.body,
    required this.allowContinueTracking,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black, // High-contrast background for focus.
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center, // Vertically center content.
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  body,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 18),
                ),
                const SizedBox(height: 32),
                if (allowContinueTracking)
                  ElevatedButton.icon(
                    onPressed: () async {
                      await AlarmPlayer.stop(); // Silence the alarm.
                      if (context.mounted) Navigator.of(context).pop(); // Return to previous screen; tracking continues.
                    },
                    icon: const Icon(Icons.notifications_off),
                    label: const Text('Stop Alarm'),
                  ),
                const SizedBox(height: 12),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                  onPressed: () async {
                    await AlarmPlayer.stop(); // Silence alarm first.
                    await TrackingService().stopTracking(); // End tracking session explicitly.
                    if (context.mounted) {
                      // Pop all the way back to the first route to reset UI state.
                      Navigator.of(context).popUntil((r) => r.isFirst);
                    }
                  },
                  icon: const Icon(Icons.stop_circle),
                  label: const Text('End Tracking'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// Post-block summary (build):
// - Presents alarm information prominently on a dark background.
// - Offers two actions depending on allowContinueTracking:
//   * Stop Alarm: stops sound and returns to prior screen, tracking continues.
//   * End Tracking: stops sound, terminates tracking, and navigates to root.
// - Uses SafeArea and centered Column for simple, focused layout.

// End-of-file summary:
// This screen is intentionally minimal to reduce friction during alerts. It
// coordinates with AlarmPlayer and TrackingService for side effects and
// navigational reset, ensuring consistent state whether a user dismisses an
// intermediate transfer alarm or ends the journey entirely.
