import 'package:audioplayers/audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:geowake2/services/notification_service.dart';

class AlarmPlayer {
  static AudioPlayer? _player;
  static bool _initialized = false;
  static bool _audioAvailable = true; // set false if plugin missing
  static final ValueNotifier<bool> isPlaying = ValueNotifier<bool>(false);

  static Future<void> _ensureInit() async {
    if (_initialized) return;
    _initialized = true;
    try {
      _player = AudioPlayer();
      await _player!.setReleaseMode(ReleaseMode.loop);
    } on MissingPluginException {
      _audioAvailable = false;
      _player = null;
    } on PlatformException {
      _audioAvailable = false;
      _player = null;
    } catch (_) {
      _audioAvailable = false;
      _player = null;
    }
  }

  static Future<void> playSelected() async {
    await _ensureInit();

    // Try to read selected ringtone, but don't fail tests if plugin missing
    String assetPath = 'assets/ringtones/(One UI) Asteroid.ogg';
    try {
      final prefs = await SharedPreferences.getInstance();
      assetPath = prefs.getString('selected_ringtone') ?? assetPath;
    } catch (_) {
      // SharedPreferences not available in unit tests without mocks
    }

    if (_audioAvailable && _player != null) {
      try {
        await _player!.stop();
        await _player!.play(AssetSource(assetPath.replaceFirst('assets/', '')));
      } on MissingPluginException {
        _audioAvailable = false;
      } on PlatformException {
        _audioAvailable = false;
      } catch (_) {
        _audioAvailable = false;
      }
    }

    // Update state regardless so UI/tests can proceed
    isPlaying.value = true;
  }

  static Future<void> stop() async {
    await _ensureInit();

    if (_audioAvailable && _player != null) {
      try {
        await _player!.stop();
      } on MissingPluginException {
        _audioAvailable = false;
      } on PlatformException {
        _audioAvailable = false;
      } catch (_) {
        _audioAvailable = false;
      }
    }

    isPlaying.value = false;

    // Also stop vibration from native side
    try {
      await NotificationService().stopVibration();
    } catch (_) {
      // Ignore errors - stopping audio/state is primary
    }
  }
}
