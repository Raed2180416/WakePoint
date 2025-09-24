// docs/annotated/screens/ringtones_screen.annotated.dart
// Annotated copy of lib/screens/ringtones_screen.dart
// Purpose: Beginner-clear, line-by-line, post-block, and EOF explanations. Lives in docs only.

// Flutter material widgets for building the UI structure and controls.
import 'package:flutter/material.dart';

// Audio player package used to preview ringtones from bundled assets.
import 'package:audioplayers/audioplayers.dart';

// Typography convenience; used to style the AppBar title nicely.
import 'package:google_fonts/google_fonts.dart';

// Lightweight key/value storage to persist the selected ringtone across launches.
import 'package:shared_preferences/shared_preferences.dart';

// Simple data model describing a ringtone option: display name + asset path.
class Ringtone {
  final String name; // Human-friendly title shown in the list
  final String assetPath; // Path within app assets where the sound file lives

  const Ringtone({required this.name, required this.assetPath});
}

// Catalog of ringtones presented by this screen. These paths must exist under assets/.
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

// The screen widget allowing users to preview and select their ringtone.
class RingtonesScreen extends StatefulWidget {
  const RingtonesScreen({super.key});

  @override
  State<RingtonesScreen> createState() => _RingtonesScreenState();
}

// Backing state for the screen; holds player instance and selection state.
class _RingtonesScreenState extends State<RingtonesScreen> {
  late AudioPlayer _audioPlayer; // Created in initState, disposed in dispose
  String? _currentlyPlayingPath; // Tracks which asset is playing for UI icon state
  String? _selectedRingtonePath; // Persisted selection reflected by Radio buttons

  // SharedPreferences key used to store the selected asset path.
  static const String ringtonePrefKey = 'selected_ringtone';

  // Initialize the player and load any previously saved selection.
  @override
  void initState() {
    super.initState();
    _audioPlayer = AudioPlayer();
    _loadSelectedRingtone();
  }

  // Clean up the player to free native resources.
  @override
  void dispose() {
    _audioPlayer.dispose();
    super.dispose();
  }

  // Load saved selection from SharedPreferences; default to first in catalog.
  Future<void> _loadSelectedRingtone() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _selectedRingtonePath =
          prefs.getString(ringtonePrefKey) ?? availableRingtones.first.assetPath;
    });
  }

  // Persist a new selection so it survives app restarts.
  Future<void> _saveSelectedRingtone(String assetPath) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(ringtonePrefKey, assetPath);
  }

  // Toggle preview playback for a given asset. Stops previous preview if needed.
  void _togglePreview(String assetPath) {
    if (_currentlyPlayingPath == assetPath) {
      _audioPlayer.stop();
      setState(() {
        _currentlyPlayingPath = null;
      });
    } else {
      _audioPlayer.stop();
      // audioplayers expects paths relative to assets/ when using AssetSource
      _audioPlayer.play(AssetSource(assetPath.replaceFirst('assets/', '')));
      setState(() {
        _currentlyPlayingPath = assetPath;
      });
    }
  }

  // Handle selecting a ringtone: update state and persist.
  void _onRingtoneSelected(String assetPath) {
    setState(() {
      _selectedRingtonePath = assetPath;
    });
    _saveSelectedRingtone(assetPath);
  }

  // Build the UI: an AppBar and a ListView of ringtone rows.
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Select Ringtone',
          style: GoogleFonts.montserrat(fontWeight: FontWeight.w600),
        ),
      ),
      body: ListView.builder(
        itemCount: availableRingtones.length,
        itemBuilder: (context, index) {
          final ringtone = availableRingtones[index];
          final bool isSelected = _selectedRingtonePath == ringtone.assetPath;
          final bool isPlaying = _currentlyPlayingPath == ringtone.assetPath;

          return Material(
            color: isSelected
                ? Theme.of(context).colorScheme.primary.withOpacity(0.1)
                : Colors.transparent,
            child: ListTile(
              onTap: () => _onRingtoneSelected(ringtone.assetPath),
              leading: Radio<String>(
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
                  fontWeight:
                      isSelected ? FontWeight.bold : FontWeight.normal,
                ),
              ),
              trailing: IconButton(
                icon: Icon(
                    isPlaying ? Icons.pause_circle_filled : Icons.play_circle_fill),
                color: Theme.of(context).colorScheme.primary,
                iconSize: 30,
                onPressed: () => _togglePreview(ringtone.assetPath),
              ),
            ),
          );
        },
      ),
    );
  }
}

// Post-block summaries:
// - Model: Ringtone encapsulates display and asset path; immutable via const.
// - Catalog: availableRingtones provides the list used by the builder; ensure assets exist and are declared in pubspec.
// - State: _audioPlayer handles preview; _currentlyPlayingPath controls icon; _selectedRingtonePath persists via SharedPreferences.
// - Lifecycle: initState creates player and loads selection; dispose releases the player.
// - Logic: _togglePreview stops any current playback before playing the new asset; _onRingtoneSelected updates selection and saves it.
// - UI: ListView.builder renders radio + title + play/pause icon; selected row highlighted subtly.

// End-of-file summary:
// This screen offers a simple and accessible way to preview and select alarm
// sounds bundled with the app. Choices are persisted with SharedPreferences.
// The implementation isolates concerns: model/catalog, state management,
// persistence, and UI. It intentionally avoids runtime code modifications
// elsewhere: this annotated file exists only under docs/ for reference.
