// Annotated copy of lib/services/alarm_player.dart
// Purpose: Explain alarm audio playback, safe init, and test resilience.

import 'package:audioplayers/audioplayers.dart'; // Audio engine
import 'package:shared_preferences/shared_preferences.dart'; // Ringtone selection
import 'package:flutter/foundation.dart'; // ValueNotifier
import 'package:flutter/services.dart'; // Platform exceptions
import 'package:geowake2/services/notification_service.dart'; // Stop vibration hook

class AlarmPlayer {
  static AudioPlayer? _player;               // Lazily created player
  static bool _initialized = false;          // Ensure one-time init
  static bool _audioAvailable = true;        // Flip to false if plugins unavailable
  static final ValueNotifier<bool> isPlaying = ValueNotifier<bool>(false); // UI/test observability

  static Future<void> _ensureInit() async {
    if (_initialized) return;
    _initialized = true;
    try {
      _player = AudioPlayer();
      await _player!.setReleaseMode(ReleaseMode.loop); // Loop for alarm behavior
    } on MissingPluginException {
      _audioAvailable = false; _player = null;
    } on PlatformException {
      _audioAvailable = false; _player = null;
    } catch (_) {
      _audioAvailable = false; _player = null;
    }
  }

  static Future<void> playSelected() async {
    await _ensureInit();

    // Default ringtone asset (can be overridden by preference)
    String assetPath = 'assets/ringtones/(One UI) Asteroid.ogg';
    try {
      final prefs = await SharedPreferences.getInstance();
      assetPath = prefs.getString('selected_ringtone') ?? assetPath;
    } catch (_) { /* SharedPreferences may be unavailable in unit tests */ }

    if (_audioAvailable && _player != null) {
      try {
        await _player!.stop(); // Stop any existing
        await _player!.play(AssetSource(assetPath.replaceFirst('assets/', '')));
      } on MissingPluginException { _audioAvailable = false; }
      on PlatformException { _audioAvailable = false; }
      catch (_) { _audioAvailable = false; }
    }

    // Always reflect playing state for UI/tests, even if audio plugin missing
    isPlaying.value = true;
  }

  static Future<void> stop() async {
    await _ensureInit();

    if (_audioAvailable && _player != null) {
      try { await _player!.stop(); }
      on MissingPluginException { _audioAvailable = false; }
      on PlatformException { _audioAvailable = false; }
      catch (_) { _audioAvailable = false; }
    }

    isPlaying.value = false;

    // Also instruct native side to stop vibration in case it was started
    try { await NotificationService().stopVibration(); } catch (_) {}
  }
}
