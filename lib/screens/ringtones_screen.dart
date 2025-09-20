// lib/screens/ringtones_screen.dart

// =========================================================================
// SECTION 1: IMPORTS (The Toolbox)
// =========================================================================
// This is the main toolkit from Flutter for building user interfaces.
// It gives us access to widgets like Scaffold, AppBar, ListView, Text, etc.
import 'package:flutter/material.dart';

// This is the special package we added to play audio files.
import 'package:audioplayers/audioplayers.dart';

// This package helps us use custom fonts easily, like the ones from Google Fonts.
import 'package:google_fonts/google_fonts.dart';

// This package lets us save and read small pieces of data on the user's device.
// We use it to remember which ringtone the user selected.
import 'package:shared_preferences/shared_preferences.dart';

// =========================================================================
// SECTION 2: THE DATA MODEL (The Blueprint)
// =========================================================================
// Before we build a list of ringtones, we create a "blueprint" for what a
// single ringtone looks like. This keeps our code clean and organized.
class Ringtone {
  final String name;      // The pretty name the user will see, e.g., "Classic Alarm"
  final String assetPath; // The exact file path for the app to find the sound

  const Ringtone({required this.name, required this.assetPath});
}

// Now we use our blueprint to create a "catalog" of all available ringtones.
// This list is what our screen will use to build the UI.
// I have transcribed the filenames exactly from the image you provided.
final List<Ringtone> availableRingtones = [
  const Ringtone(name: 'Asteroid', assetPath: 'assets/ringtones/(One UI) Asteroid.ogg'),
  const Ringtone(name: 'Atomic Bell', assetPath: 'assets/ringtones/(One UI) Atomic Bell.ogg'),
  const Ringtone(name: 'Beep-Beep', assetPath: 'assets/ringtones/(One UI) Beep-Beep.ogg'),
  const Ringtone(name: 'Comet', assetPath: 'assets/ringtones/(One UI) Comet.ogg'),
  const Ringtone(name: 'Cosmos', assetPath: 'assets/ringtones/(One UI) Cosmos.ogg'),
  const Ringtone(name: 'Galaxy Bells', assetPath: 'assets/ringtones/(One UI) Galaxy Bells.ogg'),
  const Ringtone(name: 'Over the Horizon', assetPath: 'assets/ringtones/(One UI) Media_preview_Over_the_horizon (2019).ogg'),
  const Ringtone(name: 'Neon', assetPath: 'assets/ringtones/(One UI) Neon.ogg'),
  const Ringtone(name: 'Outer Bell', assetPath: 'assets/ringtones/(One UI) Outer Bell.ogg'),
  const Ringtone(name: 'Pluto', assetPath: 'assets/ringtones/(One UI) Pluto.ogg'),
  const Ringtone(name: 'Single Tone', assetPath: 'assets/ringtones/(One UI) Single Tone.ogg'),
];

// =========================================================================
// SECTION 3: THE WIDGET (The "Living" Screen)
// =========================================================================
// We use a StatefulWidget because our screen needs to "remember" things that
// change: which ringtone is selected and which one is currently playing.
// A StatelessWidget is static, like a poster. A StatefulWidget is interactive.
class RingtonesScreen extends StatefulWidget {
  const RingtonesScreen({super.key});

  @override
  State<RingtonesScreen> createState() => _RingtonesScreenState();
}

// This is the "brain" of our widget. It holds all the memory (the "state").
class _RingtonesScreenState extends State<RingtonesScreen> {

  // =========================================================================
  // SECTION 4: STATE VARIABLES (The Screen's Memory)
  // =========================================================================
  late AudioPlayer _audioPlayer; // This will hold our audio playing tool. `late` is a promise we'll create it before using it.
  String? _currentlyPlayingPath; // Remembers which song is playing so we can show a "pause" icon. The `?` means it's okay if nothing is playing.
  String? _selectedRingtonePath; // Remembers the user's final choice. This determines which radio button is checked.

  // This is like a "label" for the data we save. When we save the ringtone choice,
  // we put it in a box with this label so we can easily find it again later.
  static const String ringtonePrefKey = 'selected_ringtone';

  // =========================================================================
  // SECTION 5: LIFECYCLE METHODS (Setup and Cleanup)
  // =========================================================================
  @override
  void initState() {
    super.initState();
    // initState is the very first thing that runs when the screen is created.
    // It's the perfect place to do setup tasks.
    _audioPlayer = AudioPlayer(); // Create our audio player instance.
    _loadSelectedRingtone(); // Immediately try to load the user's previously saved choice.
  }

  @override
  void dispose() {
    // dispose is the very last thing that runs when the screen is destroyed.
    // It's crucial for cleanup to prevent memory leaks.
    _audioPlayer.dispose(); // Release the audio player from memory.
    super.dispose();
  }

  // =========================================================================
  // SECTION 6: CORE LOGIC (The Functions that "Do Stuff")
  // =========================================================================
  
  // This function loads the saved ringtone from the device's local storage.
  Future<void> _loadSelectedRingtone() async {
    final prefs = await SharedPreferences.getInstance(); // Get access to the storage.
    setState(() {
      // Try to read the string with our special key.
      // If it doesn't exist (e.g., first time app launch), default to the first ringtone in our list.
      _selectedRingtonePath = prefs.getString(ringtonePrefKey) ?? availableRingtones.first.assetPath;
    });
  }

  // This function saves the user's ringtone choice.
  Future<void> _saveSelectedRingtone(String assetPath) async {
    final prefs = await SharedPreferences.getInstance(); // Get access to the storage.
    await prefs.setString(ringtonePrefKey, assetPath); // Save the chosen path with our key.
  }

  // This function handles the play/pause button for previews.
  void _togglePreview(String assetPath) {
    // If the user taps the play button for the sound that's already playing...
    if (_currentlyPlayingPath == assetPath) {
      _audioPlayer.stop(); // ...stop it.
      setState(() { _currentlyPlayingPath = null; }); // Forget what was playing.
    } else {
      // If they tap a new sound...
      _audioPlayer.stop(); // ...stop anything that might have been playing before.
      // The `AssetSource` tells the player to look in your `assets` folder.
      // The `replaceFirst` is needed because the player package expects the path without the initial 'assets/'.
      _audioPlayer.play(AssetSource(assetPath.replaceFirst('assets/', '')));
      setState(() { _currentlyPlayingPath = assetPath; }); // Remember the new sound that's playing.
    }
  }

  // This function runs when the user taps on a ringtone row to select it.
  void _onRingtoneSelected(String assetPath) {
    // setState tells Flutter that our screen's memory has changed and it needs to redraw itself.
    setState(() {
      _selectedRingtonePath = assetPath; // Update our memory with the new selection.
    });
    _saveSelectedRingtone(assetPath); // Immediately save the new choice.
  }

  // =========================================================================
  // SECTION 7: THE BUILD METHOD (Constructing the Visuals)
  // =========================================================================
  // The build method is like the set of instructions that tells Flutter what to draw on the screen.
  // It runs every time `setState` is called.
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Select Ringtone',
          style: GoogleFonts.montserrat(fontWeight: FontWeight.w600), // Use a nice font
        ),
      ),
      // ListView.builder is the best way to create a list. It's efficient because
      // it only builds the items that are currently visible on the screen.
      body: ListView.builder(
        itemCount: availableRingtones.length, // Tell the list how many items to build.
        itemBuilder: (context, index) {
          // This function is called for each item in the list.
          final ringtone = availableRingtones[index]; // Get the ringtone for the current row.
          final bool isSelected = _selectedRingtonePath == ringtone.assetPath; // Check if this row is the selected one.
          final bool isPlaying = _currentlyPlayingPath == ringtone.assetPath;  // Check if this row's sound is playing.

          // Material and ListTile give us the standard row appearance.
          return Material(
            // Give a subtle background color to the selected item.
            color: isSelected ? Theme.of(context).colorScheme.primary.withOpacity(0.1) : Colors.transparent,
            child: ListTile(
              onTap: () => _onRingtoneSelected(ringtone.assetPath), // Make the whole row tappable.
              leading: Radio<String>(
                // The radio button is visually "on" when its `value` matches the `groupValue`.
                value: ringtone.assetPath,
                groupValue: _selectedRingtonePath,
                onChanged: (value) {
                  if (value != null) {
                    _onRingtoneSelected(value);
                  }
                },
              ),
              title: Text(
                ringtone.name,
                style: TextStyle(
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal, // Make the selected text bold.
                ),
              ),
              trailing: IconButton(
                // This is a compact if/else statement: `condition ? value_if_true : value_if_false`
                // It chooses the icon based on whether the sound is playing.
                icon: Icon(isPlaying ? Icons.pause_circle_filled : Icons.play_circle_fill),
                color: Theme.of(context).colorScheme.primary,
                iconSize: 30,
                onPressed: () => _togglePreview(ringtone.assetPath), // The button calls our play/pause logic.
              ),
            ),
          );
        },
      ),
    );
  }
}