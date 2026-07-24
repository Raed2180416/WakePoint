import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:geowake2/services/notification_service.dart';
import 'package:geowake2/services/monetization/monetization_service.dart';

class AlarmPlayer {
  /// The free, always-available alarm sound. Playback falls back to this
  /// whenever no custom ringtone is selected OR the entitlement that unlocked
  /// custom ringtones (Pro / an active rewarded day-pass) has lapsed — the
  /// alarm itself must never silently break or go quiet because a day-pass
  /// expired, so it fails toward this default rather than toward silence.
  static const String defaultRingtoneAsset =
      'assets/ringtones/(One UI) Asteroid.ogg';

  static AudioPlayer? _player;
  static bool _initialized = false;
  static bool _audioAvailable = true; // set false if plugin missing
  static final ValueNotifier<bool> isPlaying = ValueNotifier<bool>(false);

  // Resolved asset path from the most recent playSelected() call. The real
  // audioplayers plugin channel isn't available headless, so this is the
  // observable seam tests use to verify the default-vs-custom-ringtone
  // entitlement fallback without mocking the platform channel.
  static String? _lastResolvedAssetPath;
  @visibleForTesting
  static String? get lastResolvedAssetPathForTests => _lastResolvedAssetPath;

  // G8: native hook that fires when a routed BT/wired headset disconnects
  // (Android AudioManager.ACTION_AUDIO_BECOMING_NOISY). See MainActivity.kt.
  static const MethodChannel _audioRouteChannel = MethodChannel(
    'geowake/alarm_audio',
  );

  // G9b: gentle volume escalation. The alarm starts quiet and ramps to full so
  // a deep sleeper is reliably woken without a jarring full-volume blast.
  static const double _rampStartVolume = 0.25;
  static const double _rampEndVolume = 1.0;
  static const int _rampSteps = 12;
  static const Duration _rampStepInterval = Duration(milliseconds: 400);
  static Timer? _rampTimer;
  // Tracks the current ramp volume so route re-assertion (G8) restores the
  // correct level instead of jumping to full.
  static double _currentVolume = _rampEndVolume;

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
    // G8: listen for the native audio-becoming-noisy signal so we can force the
    // alarm back onto the loudspeaker when a headset disconnects mid-alarm.
    try {
      _audioRouteChannel.setMethodCallHandler(_handleNativeAudioRouteCall);
    } catch (_) {}

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
    String assetPath = defaultRingtoneAsset;
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString('selected_ringtone');
      // A custom ringtone is only honored while the entitlement that unlocked
      // it (Pro / an active rewarded day-pass) is CURRENTLY active. The
      // selection can outlive a lapsed day-pass in prefs (nothing clears it
      // on expiry), so re-check at play-time rather than trusting the saved
      // value — and fail toward the default sound, never toward a silently
      // broken/unentitled alarm.
      if (saved != null) {
        final canUseCustom =
            MonetizationService.instance.premiumOrNull?.canUseCustomAlarmSounds ??
                false;
        assetPath = canUseCustom ? saved : defaultRingtoneAsset;
      }
    } catch (_) {
      // SharedPreferences not available in unit tests without mocks
    }
    _lastResolvedAssetPath = assetPath;

    if (_audioAvailable && _player != null) {
      try {
        // Re-apply context at play-time too (some OEM stacks reset audio attrs
        // when isolates restart, when app is backgrounded, etc.).
        await _configureAlarmAudioRoute();
        await _player!.stop();
        // G9b: start quiet, then ramp up (see _startVolumeRamp). Audible
        // escalation itself can only be judged on real hardware.
        // DEVICE-VERIFY: volume ramp loudness/audibility on a physical device.
        _stopVolumeRamp();
        try {
          await _player!.setVolume(_rampStartVolume);
        } catch (_) {}
        await _player!.play(AssetSource(assetPath.replaceFirst('assets/', '')));
        _startVolumeRamp();
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

  // G9b: drive the gentle volume escalation from [_rampStartVolume] up to
  // [_rampEndVolume] over ~[_rampSteps] * [_rampStepInterval].
  static void _startVolumeRamp() {
    _rampTimer?.cancel();
    _currentVolume = _rampStartVolume;
    _setVolumeSafe(_currentVolume);
    var step = 0;
    _rampTimer = Timer.periodic(_rampStepInterval, (t) {
      step++;
      final v = (_rampStartVolume +
              (_rampEndVolume - _rampStartVolume) * (step / _rampSteps))
          .clamp(_rampStartVolume, _rampEndVolume);
      _currentVolume = v;
      _setVolumeSafe(v);
      if (step >= _rampSteps) {
        t.cancel();
        _rampTimer = null;
      }
    });
  }

  static void _stopVolumeRamp() {
    _rampTimer?.cancel();
    _rampTimer = null;
    _currentVolume = _rampEndVolume;
  }

  static void _setVolumeSafe(double v) {
    final p = _player;
    if (!_audioAvailable || p == null) return;
    // Fire-and-forget: volume changes must not stall the ramp cadence.
    p.setVolume(v).catchError((_) {});
  }

  static Future<dynamic> _handleNativeAudioRouteCall(MethodCall call) async {
    if (call.method == 'audioBecomingNoisy') {
      await _onAudioBecomingNoisy();
    }
    return null;
  }

  /// G8: a routed BT/wired headset just disconnected. Android auto-reroutes the
  /// alarm stream to the loudspeaker, but some OEM audio stacks leave the player
  /// pinned to the now-dead route, so the rider hears nothing. Re-assert the
  /// alarm audio attributes (forces the alarm/loudspeaker output) and re-apply
  /// the current ramp volume. The vibration loop keeps running independently as
  /// the tactile fallback, so a rider is still alerted even if audio is lost.
  // DEVICE-VERIFY: headset/BT disconnect rerouting to loudspeaker can only be
  // proven on a physical device with real audio hardware.
  static Future<void> _onAudioBecomingNoisy() async {
    if (!_audioAvailable || _player == null) return;
    if (!isPlaying.value) return;
    try {
      await _configureAlarmAudioRoute();
      await _player!.setVolume(_currentVolume);
    } catch (_) {
      // Best-effort: vibration fallback still alerts the rider.
    }
  }

  static Future<void> stop() async {
    await _ensureInit();

    _stopVolumeRamp();

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
