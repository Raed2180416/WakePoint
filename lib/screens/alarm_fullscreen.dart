import 'package:flutter/material.dart';
import 'package:geowake2/services/alarm_player.dart';
import 'package:geowake2/services/trackingservice.dart';

class AlarmFullscreen extends StatelessWidget {
  final String title;
  final String body;
  final bool allowContinueTracking; // true for transfer alarms
  const AlarmFullscreen({super.key, required this.title, required this.body, required this.allowContinueTracking});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(title, style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                Text(body, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, fontSize: 18)),
                const SizedBox(height: 32),
                if (allowContinueTracking)
                  ElevatedButton.icon(
                    onPressed: () async {
                      await AlarmPlayer.stop();
                      if (context.mounted) Navigator.of(context).pop();
                    },
                    icon: const Icon(Icons.notifications_off),
                    label: const Text('Stop Alarm'),
                  ),
                const SizedBox(height: 12),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                  onPressed: () async {
                    await AlarmPlayer.stop();
                    await TrackingService().stopTracking();
                    if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
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
