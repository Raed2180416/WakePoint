// docs/annotated/screens/settingsdrawer.annotated.dart
// Annotated copy of lib/screens/settingsdrawer.dart
// Purpose: Provide beginner-clear, line-by-line, post-block, and EOF explanations.
// Note: Lives in docs/ only; does not affect runtime. Imports use package paths
// so the analyzer can resolve symbols when viewing this file in isolation.

// Import the core Flutter material UI library.
import 'package:flutter/material.dart'; // Provides widgets like Drawer, ListView, ListTile, etc.

// Import the app's root state to read and toggle theme (dark/light).
import 'package:geowake2/main.dart'; // Exposes MyAppState for theme toggling.

// Import the ringtones screen to navigate to it from the drawer.
import 'package:geowake2/screens/ringtones_screen.dart'; // Destination for "Alarm Ringtones" menu item.

// A stateless widget that renders the application's settings drawer.
class SettingsDrawer extends StatelessWidget {
  const SettingsDrawer({super.key}); // Simple const constructor; drawer has no mutable state.

  // Build method describes how to render the drawer UI.
  @override
  Widget build(BuildContext context) {
    // Look up the nearest ancestor state of type MyAppState to access global theme toggling.
    final appState = context.findAncestorStateOfType<MyAppState>();
    // Determine whether dark mode is currently enabled; default to false if appState is absent.
    final isDarkMode = appState?.isDarkMode ?? false;

    // Return the actual drawer widget.
    return Drawer(
      // SafeArea ensures we avoid notches/status bars.
      child: SafeArea(
        // Use a ListView so items can scroll if needed; padding zero matches native drawer feel.
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            // A decorative header for the drawer.
            const DrawerHeader(
              decoration: BoxDecoration(color: Colors.deepPurple),
              child: Text(
                'Settings',
                style: TextStyle(
                  fontFamily: 'Pacifico', // Keep typography consistent with the rest of the app.
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            // Theme toggle tile: switches between dark and light.
            ListTile(
              leading: Icon(
                isDarkMode ? Icons.wb_sunny : Icons.nightlight_round, // Icon reflects the target mode after tap.
              ),
              title: Text(isDarkMode ? 'Light Mode' : 'Dark Mode'), // Title reflects action.
              onTap: () {
                appState?.toggleTheme(); // Ask the app to toggle theme.
                Navigator.of(context).pop(); // Close the drawer after the action.
              },
            ),
            // Navigate to the ringtones selection screen.
            ListTile(
              leading: const Icon(Icons.alarm),
              title: const Text('Alarm Ringtones'),
              onTap: () {
                // Close the drawer first for a smooth UX.
                Navigator.of(context).pop();
                // Push the ringtones screen.
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (context) => const RingtonesScreen()),
                );
              },
            ),
            // Placeholder for premium flow entry point.
            ListTile(
              leading: const Icon(Icons.star),
              title: const Text('Go Premium'),
              onTap: () {
                // TODO: Implement premium purchase flow.
              },
            ),
            // Visual divider between primary and secondary actions.
            const Divider(),
            // Close drawer tile.
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('Close'),
              onTap: () {
                Navigator.of(context).pop(); // Just close the drawer.
              },
            ),
          ],
        ),
      ),
    );
  }
}

// Post-block summary (build):
// - Reads theme from MyAppState, renders drawer with header and four items:
//   1) Theme toggle (updates app theme and closes drawer)
//   2) Alarm Ringtones (navigates to RingtonesScreen after closing drawer)
//   3) Go Premium (placeholder for future in-app purchase flow)
//   4) Close (simply closes the drawer)
// - Uses SafeArea and ListView for proper layout and scrollability.

// End-of-file summary:
// This drawer centralizes quick-access settings and navigation. The only external
// dependency on app state is the theme toggle via MyAppState, which keeps this
// widget stateless and easy to reason about. Navigation to RingtonesScreen uses
// MaterialPageRoute for simplicity. The structure is intentionally minimal and
// discoverable, suitable for extension (e.g., adding more ListTiles later).
