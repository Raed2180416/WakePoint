// lib/services/anti_theft_service.dart
//
// Pro-gated anti-theft protection for transit riders. SOTA snatch detection
// fusing user-accelerometer (gravity-removed linear acceleration) + gyroscope
// (angular velocity) with an adaptive Z-score baseline.
//
// Detection model (reconciled with SOTA research, July 2026):
//
// 1. **User-accelerometer thresholds** calibrated to Snatch Guard's 2.0G–6.0G
//    range (snatchguard.app). We use userAccelerometer (gravity-removed) so
//    thresholds map directly to pure G-force without gravity offset.
//
// 2. **Gyroscope fusion** — a snatch involves not just linear acceleration but
//    also rotation as the thief grabs and twists the phone away. Requiring both
//    an accel spike AND a gyro angular-velocity spike discriminates snatches
//    from linear bumps (potholes, rail joints) that have high accel but low
//    rotation. (Liu et al., "Detecting Phone Theft Using ML", ICISS 2018;
//    iGuard, IEEE INFOCOM 2017.)
//
// 3. **Rolling Z-score baseline** (ShadowID approach) — maintains a sliding
//    window of recent acceleration magnitudes. If a sample exceeds mean +
//    N×std, it's flagged as anomalous relative to the current transit context.
//    This adapts: a bumpy bus ride raises the baseline so only truly abnormal
//    spikes fire; a smooth train keeps the baseline low so subtle grabs catch.
//
// 4. **Charger removal detection** (Thief Detector pattern, adnanamin69/MIT)
//    — if the phone is unplugged while monitoring is active, fire immediately.
//    Common SOTA anti-theft trigger for public charging scenarios.
//
// 5. **Calibration phase** — first 5 seconds of monitoring build the baseline
//    without triggering, so the act of placing the phone on a lap/seat doesn't
//    false-alarm.
//
// 6. **Cooldown** — 10s after dismissal before re-arming, preventing immediate
//    re-trigger from the user's own handling.
//
// DESIGN: fail-open. Any sensor error disables monitoring silently. The service
// never touches the arm→track→alarm spine — it reads sensors and fires its own
// alarm via NotificationService on detection.

import 'dart:async';
import 'dart:developer' as dev;
import 'dart:math' as math;

import 'package:battery_plus/battery_plus.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:geowake2/services/notification_service.dart';

/// Sensitivity levels for snatch detection. Higher sensitivity = lower
/// threshold = triggers more easily.
enum AntiTheftSensitivity { low, medium, high }

/// Monitors sensors for phone snatch while the user sleeps on transit.
/// Pro-only feature — the caller is responsible for gating.
class AntiTheftService {
  AntiTheftService._();
  static final AntiTheftService instance = AntiTheftService._();

  static const String _enabledKey = 'gw_anti_theft_enabled';
  static const String _sensitivityKey = 'gw_anti_theft_sensitivity';
  static const String _chargerKey = 'gw_anti_theft_charger';

  // ── Thresholds (user-accelerometer, gravity-removed) ─────────────────────
  //
  // Calibrated to Snatch Guard's 2.0G–6.0G range. 1G = 9.8 m/s².
  // userAccelerometer gives linear acceleration without gravity, so these
  // map directly: high = 2.0G ≈ 19.6 m/s², medium = 4.0G ≈ 39.2, low = 6.0G.
  static const Map<AntiTheftSensitivity, double> _accelThresholds = {
    AntiTheftSensitivity.low: 58.8, // 6.0G — only a hard yank
    AntiTheftSensitivity.medium: 39.2, // 4.0G — balanced
    AntiTheftSensitivity.high: 19.6, // 2.0G — most reactive
  };

  // Gyroscope angular-velocity threshold (rad/s). A snatch typically produces
  // >2 rad/s rotation; normal transit vibration stays under 1 rad/s.
  static const Map<AntiTheftSensitivity, double> _gyroThresholds = {
    AntiTheftSensitivity.low: 3.0,
    AntiTheftSensitivity.medium: 2.0,
    AntiTheftSensitivity.high: 1.2,
  };

  // Z-score threshold for adaptive anomaly detection (Path B).
  // 3.0 = 3 standard deviations above the rolling mean.
  static const double _zScoreThreshold = 3.0;

  // Rolling baseline window: 100 samples ≈ 5 seconds at 20Hz.
  static const int _baselineWindowSize = 100;

  // Calibration duration: first 5s of monitoring build baseline without firing.
  static const Duration _calibrationDuration = Duration(seconds: 5);

  // Cooldown after dismissal before re-arming.
  static const Duration _cooldownDuration = Duration(seconds: 10);

  // Confirmation window: after an accel spike, check gyro within this window.
  static const Duration _confirmWindow = Duration(milliseconds: 200);

  // ── State ────────────────────────────────────────────────────────────────

  bool _enabled = false;
  AntiTheftSensitivity _sensitivity = AntiTheftSensitivity.medium;
  bool _chargerDetection = true;

  StreamSubscription<UserAccelerometerEvent>? _accelSub;
  StreamSubscription<GyroscopeEvent>? _gyroSub;
  StreamSubscription<BatteryState>? _batterySub;

  bool _monitoring = false;
  bool _alarmFired = false;
  bool _calibrating = false;
  DateTime? _monitorStart;
  DateTime? _lastDismissed;

  // Rolling baseline for Z-score (accel magnitudes).
  final List<double> _baselineWindow = <double>[];

  // Recent gyro magnitude for fusion confirmation.
  double _recentGyroMag = 0.0;
  DateTime? _gyroTimestamp;

  // Accel spike candidate for gyro fusion confirmation.
  DateTime? _accelSpikeTime;

  // ── Public API ───────────────────────────────────────────────────────────

  bool get isEnabled => _enabled;
  AntiTheftSensitivity get sensitivity => _sensitivity;
  bool get chargerDetectionEnabled => _chargerDetection;
  bool get isMonitoring => _monitoring;
  bool get alarmFired => _alarmFired;
  bool get isCalibrating => _calibrating;

  /// Load persisted settings. Call at app start.
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(_enabledKey) ?? false;
      _chargerDetection = prefs.getBool(_chargerKey) ?? true;
      final sIndex = prefs.getInt(_sensitivityKey) ?? 1;
      _sensitivity = AntiTheftSensitivity.values.elementAtOrNull(sIndex) ??
          AntiTheftSensitivity.medium;
    } catch (_) {
      // Fail-open: defaults remain disabled + medium.
    }
  }

  /// Enable/disable anti-theft mode. Does NOT start monitoring.
  Future<void> setEnabled(bool enabled) async {
    _enabled = enabled;
    if (!enabled) await stopMonitoring();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_enabledKey, enabled);
    } catch (_) {/* best-effort */}
  }

  Future<void> setSensitivity(AntiTheftSensitivity s) async {
    _sensitivity = s;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_sensitivityKey, s.index);
    } catch (_) {/* best-effort */}
  }

  Future<void> setChargerDetection(bool enabled) async {
    _chargerDetection = enabled;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_chargerKey, enabled);
    } catch (_) {/* best-effort */}
  }

  /// Begin sensor monitoring. Called when a tracking session starts and
  /// anti-theft is enabled. No-op if already monitoring or disabled.
  Future<void> startMonitoring() async {
    if (!_enabled || _monitoring) return;

    // Respect cooldown after recent dismissal.
    if (_lastDismissed != null &&
        DateTime.now().difference(_lastDismissed!) < _cooldownDuration) {
      dev.log('Anti-theft: in cooldown, skipping start', name: 'AntiTheft');
      return;
    }

    _monitoring = true;
    _alarmFired = false;
    _calibrating = true;
    _monitorStart = DateTime.now();
    _baselineWindow.clear();
    _accelSpikeTime = null;
    _recentGyroMag = 0.0;

    // ── User-accelerometer stream (gravity-removed linear acceleration) ──
    try {
      _accelSub = userAccelerometerEventStream(
        samplingPeriod: const Duration(milliseconds: 50), // 20Hz
      ).listen(
        _onUserAccelerometerEvent,
        onError: (e) {
          dev.log('Anti-theft accel sensor error: $e', name: 'AntiTheft');
          _monitoring = false;
        },
        cancelOnError: true,
      );
    } catch (e) {
      dev.log('Anti-theft: accel stream failed: $e', name: 'AntiTheft');
    }

    // ── Gyroscope stream for rotation fusion ──
    try {
      _gyroSub = gyroscopeEventStream(
        samplingPeriod: const Duration(milliseconds: 50),
      ).listen(
        _onGyroscopeEvent,
        onError: (e) {
          dev.log('Anti-theft gyro sensor error: $e', name: 'AntiTheft');
        },
        cancelOnError: true,
      );
    } catch (e) {
      // Gyro is optional — accel-only detection still works with reduced
      // false-positive filtering.
      dev.log('Anti-theft: gyro unavailable, accel-only mode: $e',
          name: 'AntiTheft');
    }

    // ── Charger removal detection ──
    if (_chargerDetection) {
      try {
        _batterySub = Battery().onBatteryStateChanged.listen(
          _onBatteryStateChanged,
          onError: (_) {/* fail-open */},
        );
      } catch (e) {
        dev.log('Anti-theft: battery monitoring unavailable: $e',
            name: 'AntiTheft');
      }
    }

    dev.log('Anti-theft monitoring started '
        '(sensitivity: $_sensitivity, gyro: ${_gyroSub != null}, '
        'charger: $_chargerDetection)', name: 'AntiTheft');
  }

  /// Stop all monitoring and reset state.
  Future<void> stopMonitoring() async {
    _monitoring = false;
    _calibrating = false;
    _accelSpikeTime = null;
    _baselineWindow.clear();
    await _accelSub?.cancel();
    _accelSub = null;
    await _gyroSub?.cancel();
    _gyroSub = null;
    await _batterySub?.cancel();
    _batterySub = null;
  }

  // ── Sensor event handlers ────────────────────────────────────────────────

  void _onUserAccelerometerEvent(UserAccelerometerEvent event) {
    if (!_monitoring || _alarmFired) return;

    final now = DateTime.now();

    // Check calibration phase.
    if (_calibrating) {
      if (_monitorStart != null &&
          now.difference(_monitorStart!) >= _calibrationDuration) {
        _calibrating = false;
        dev.log('Anti-theft: calibration complete, baseline size=${_baselineWindow.length}',
            name: 'AntiTheft');
      }
    }

    // Linear acceleration magnitude (gravity already removed).
    final mag = math.sqrt(event.x * event.x + event.y * event.y + event.z * event.z);

    // Feed rolling baseline (even during calibration — that's the point).
    _baselineWindow.add(mag);
    if (_baselineWindow.length > _baselineWindowSize) {
      _baselineWindow.removeAt(0);
    }

    // Skip detection during calibration.
    if (_calibrating) return;

    // ── Path A: Static threshold (immediate, works from t=0 post-calibration) ──
    final accelThreshold = _accelThresholds[_sensitivity]!;
    bool pathATriggered = false;

    if (mag >= accelThreshold) {
      _accelSpikeTime ??= now;
      // Check if gyro confirms within the confirmation window.
      if (_checkGyroConfirmation()) {
        _onSnatchDetected('accel+gyro fusion (mag: ${mag.toStringAsFixed(1)} m/s²)');
        return;
      }
      // Sustained accel spike without gyro: still fire if it persists.
      if (now.difference(_accelSpikeTime!) >= const Duration(milliseconds: 300)) {
        _onSnatchDetected('sustained accel spike (mag: ${mag.toStringAsFixed(1)} m/s²)');
        return;
      }
      pathATriggered = true;
    } else {
      _accelSpikeTime = null;
    }

    // ── Path B: Z-score anomaly (adaptive, needs baseline) ──
    if (!pathATriggered && _baselineWindow.length >= 20) {
      final z = _computeZScore(mag);
      if (z >= _zScoreThreshold) {
        // Z-score anomaly: check gyro confirmation or sustained anomaly.
        if (_checkGyroConfirmation()) {
          _onSnatchDetected('Z-score anomaly (z=$z, gyro confirmed)');
          return;
        }
        // Without gyro, require a higher Z-score for standalone trigger.
        if (z >= _zScoreThreshold + 1.5) {
          _onSnatchDetected('Z-score anomaly (z=$z, standalone)');
          return;
        }
      }
    }
  }

  void _onGyroscopeEvent(GyroscopeEvent event) {
    if (!_monitoring || _alarmFired) return;

    // Angular velocity magnitude (rad/s).
    _recentGyroMag = math.sqrt(
        event.x * event.x + event.y * event.y + event.z * event.z);
    _gyroTimestamp = DateTime.now();
  }

  void _onBatteryStateChanged(BatteryState state) {
    if (!_monitoring || _alarmFired || !_chargerDetection) return;
    if (_calibrating) return; // Don't fire during calibration.

    // Charger removal: charging → discharging transition.
    if (state == BatteryState.discharging) {
      _onSnatchDetected('charger removed while monitoring');
    }
  }

  // ── Detection helpers ────────────────────────────────────────────────────

  /// Check if recent gyro magnitude exceeds the threshold within the
  /// confirmation window of an accel spike.
  bool _checkGyroConfirmation() {
    if (_gyroTimestamp == null || _recentGyroMag <= 0) return false;

    // Gyro reading must be recent (within confirmation window).
    final gyroAge = DateTime.now().difference(_gyroTimestamp!);
    if (gyroAge > _confirmWindow) return false;

    final gyroThreshold = _gyroThresholds[_sensitivity]!;
    return _recentGyroMag >= gyroThreshold;
  }

  /// Compute Z-score of [mag] against the rolling baseline.
  double _computeZScore(double mag) {
    if (_baselineWindow.length < 2) return 0.0;
    final n = _baselineWindow.length;
    double sum = 0.0;
    for (final v in _baselineWindow) {
      sum += v;
    }
    final mean = sum / n;
    double sqSum = 0.0;
    for (final v in _baselineWindow) {
      sqSum += (v - mean) * (v - mean);
    }
    final std = math.sqrt(sqSum / n);
    if (std < 0.01) return 0.0; // No variance → can't compute Z.
    return (mag - mean) / std;
  }

  // ── Alarm firing ─────────────────────────────────────────────────────────

  Future<void> _onSnatchDetected(String reason) async {
    _alarmFired = true;
    _monitoring = false;
    _calibrating = false;
    await _accelSub?.cancel();
    _accelSub = null;
    await _gyroSub?.cancel();
    _gyroSub = null;
    await _batterySub?.cancel();
    _batterySub = null;

    dev.log('ANTI-THEFT: Snatch detected ($reason). Firing alarm.',
        name: 'AntiTheft');

    try {
      await NotificationService().showWakeUpAlarm(
        title: '🚨 Anti-theft alarm!',
        body: 'Your phone was moved while you were sleeping. '
            'Stop the alarm if you have your phone.',
        allowContinueTracking: false,
        playSound: true,
      );
    } catch (e) {
      dev.log('Anti-theft alarm trigger failed: $e', name: 'AntiTheft');
    }
  }

  /// Dismiss the anti-theft alarm. Resets state with cooldown.
  Future<void> dismiss() async {
    _alarmFired = false;
    _lastDismissed = DateTime.now();
    try {
      await NotificationService().cancelAlarm();
    } catch (_) {/* best-effort */}
  }

  /// Reset alarm state after dismissal (called from UI).
  void resetAlarmState() {
    _alarmFired = false;
    _lastDismissed = DateTime.now();
  }

  Future<void> dispose() async {
    await stopMonitoring();
  }
}
