package com.example.geowake2

import io.flutter.app.FlutterApplication

/**
 * Custom Application so notification channels are created for EVERY process
 * start — not only when the UI Activity launches. This closes the reboot hole:
 * the OS-scheduled exact-alarm backstop can fire from the background service /
 * AlarmManager receiver after a mid-journey reboot with the UI never launched,
 * and it must post to a channel that already carries the system alarm tone +
 * DND bypass. See NotificationChannels for the full rationale.
 *
 * Wired via android:name="${applicationName}" (manifestPlaceholders in
 * app/build.gradle) → com.example.geowake2.GeoWakeApplication.
 */
class GeoWakeApplication : FlutterApplication() {
    override fun onCreate() {
        super.onCreate()
        try {
            NotificationChannels.ensure(this)
        } catch (t: Throwable) {
            // Never let channel setup crash app/process startup; MainActivity
            // also calls ensure() as a backstop for the UI path.
        }
    }
}
