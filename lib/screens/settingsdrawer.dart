// lib/screens/settingsdrawer.dart

import 'package:flutter/material.dart';
import '../main.dart';

// --- STEP 1: ADD THIS IMPORT ---
// This line tells our settings drawer that the RingtonesScreen exists and where to find it.
import 'package:geowake2/screens/ringtones_screen.dart';

 
class SettingsDrawer extends StatelessWidget {
  const SettingsDrawer({super.key});

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
            ListTile(
              leading: const Icon(Icons.alarm),
              title: const Text('Alarm Ringtones'),
              // --- STEP 2: UPDATE THIS onTap FUNCTION ---
              onTap: () {
                // This closes the drawer before navigating to the new screen
                // for a smoother user experience.
                Navigator.of(context).pop();
                
                // This is the command that pushes the RingtonesScreen onto the view.
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (context) => const RingtonesScreen(),
                ));
              },
            ),
            ListTile(
              leading: const Icon(Icons.star),
              title: const Text('Go Premium'),
              onTap: () {
                // Implement premium purchase flow
              },
            ),
            const Divider(),
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