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

  static final AudioContext _alarmAudioContext = AudioContext(
    android: AudioContextAndroid(
      contentType: AndroidContentType.sonification,
      usageType: AndroidUsageType.alarm,
      audioFocus: AndroidAudioFocus.gainTransient,
      stayAwake: true,
    ),
    iOS: AudioContextIOS(
      category: AVAudioSessionCategory.playback,
      options: <AVAudioSessionOptions>{AVAudioSessionOptions.mixWithOthers},
    ),
  );

  static Future<void> _configureAlarmAudioRoute() async {
    if (!_audioAvailable || _player == null) return;
    try {
      // Critical UX fix:
      // - Default playback uses the media stream on Android.
      // - If the user’s media volume is 0 but alarm volume is non-zero,
      //   the alarm will appear “silent” until they press volume buttons.
      // Force alarm-appropriate attributes so it routes to the ALARM stream.
      await _player!.setAudioContext(_alarmAudioContext);
    } catch (_) {
      // Best-effort: keep playback functional even if context APIs differ
      // across platforms/versions.
    }
  }

  static Future<void> _ensureInit() async {
    if (_initialized) return;
    _initialized = true;
    try {
      _player = AudioPlayer();
      // Prefer MediaPlayer-style playback for alarm-like looping reliability.
      // (SoundPool/low-latency can be flaky for long looping assets.)
      try {
        await _player!.setPlayerMode(PlayerMode.mediaPlayer);
      } catch (_) {}

      await _configureAlarmAudioRoute();
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
        // Re-apply context at play-time too (some OEM stacks reset audio attrs
        // when isolates restart, when app is backgrounded, etc.).
        await _configureAlarmAudioRoute();
        await _player!.stop();
        try {
          await _player!.setVolume(1.0);
        } catch (_) {}
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

  /// Mark the alarm as playing without actually playing audio.
  /// Used when the background isolate plays the sound but the foreground UI
  /// needs to know an alarm is active (for Stop Alarm button state).
  static void markAsPlaying() {
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
