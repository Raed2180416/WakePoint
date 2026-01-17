// EKF telemetry ring buffer logger (§12 + §22.12).
//
// Produces CSV logs compatible with simulation playground.
// Ring buffer limited to 10 MB per session; oldest records dropped.

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'ekf_types.dart';

/// A single telemetry record for CSV serialization.
class EkfLogEntry {
  EkfLogEntry({
    required this.monotonicMs,
    required this.wallClockMs,
    this.imuAx,
    this.imuAy,
    this.imuAz,
    this.imuGx,
    this.imuGy,
    this.imuGz,
    this.gravityX,
    this.gravityY,
    this.gravityZ,
    this.filteredAx,
    this.filteredAy,
    this.filteredAz,
    this.ekfS,
    this.ekfV,
    this.ekfBiasA,
    this.sigmaS,
    this.sigmaV,
    this.gpsLat,
    this.gpsLng,
    this.gpsAccuracy,
    this.gpsInnovation,
    this.gpsInnovationSigma,
    this.motionState,
    this.zuptEvent,
    this.zuptDwell,
    this.mode,
    this.stationSnapIndex,
  });

  final int monotonicMs;
  final int wallClockMs;

  // Raw IMU (m/s², rad/s)
  final double? imuAx;
  final double? imuAy;
  final double? imuAz;
  final double? imuGx;
  final double? imuGy;
  final double? imuGz;

  // Gravity estimate (unit vector)
  final double? gravityX;
  final double? gravityY;
  final double? gravityZ;

  // Filtered / world-frame accel
  final double? filteredAx;
  final double? filteredAy;
  final double? filteredAz;

  // EKF state
  final double? ekfS;
  final double? ekfV;
  final double? ekfBiasA;
  final double? sigmaS;
  final double? sigmaV;

  // GPS update
  final double? gpsLat;
  final double? gpsLng;
  final double? gpsAccuracy;
  final double? gpsInnovation;
  final double? gpsInnovationSigma;

  // Motion classification
  final String? motionState;

  // ZUPT events
  final String? zuptEvent; // 'candidate', 'confirmed', null
  final double? zuptDwell;

  // Mode and station
  final String? mode;
  final int? stationSnapIndex;

  static const _headers = [
    'monotonic_ms',
    'wall_clock_ms',
    'imu_ax',
    'imu_ay',
    'imu_az',
    'imu_gx',
    'imu_gy',
    'imu_gz',
    'gravity_x',
    'gravity_y',
    'gravity_z',
    'filtered_ax',
    'filtered_ay',
    'filtered_az',
    'ekf_s',
    'ekf_v',
    'ekf_bias_a',
    'sigma_s',
    'sigma_v',
    'gps_lat',
    'gps_lng',
    'gps_accuracy',
    'gps_innovation',
    'gps_innovation_sigma',
    'motion_state',
    'zupt_event',
    'zupt_dwell',
    'mode',
    'station_snap_index',
  ];

  static String headerLine() => _headers.join(',');

  String toCsvLine() {
    return [
      monotonicMs,
      wallClockMs,
      _fmt(imuAx),
      _fmt(imuAy),
      _fmt(imuAz),
      _fmt(imuGx),
      _fmt(imuGy),
      _fmt(imuGz),
      _fmt(gravityX),
      _fmt(gravityY),
      _fmt(gravityZ),
      _fmt(filteredAx),
      _fmt(filteredAy),
      _fmt(filteredAz),
      _fmt(ekfS),
      _fmt(ekfV),
      _fmt(ekfBiasA),
      _fmt(sigmaS),
      _fmt(sigmaV),
      _fmt(gpsLat),
      _fmt(gpsLng),
      _fmt(gpsAccuracy),
      _fmt(gpsInnovation),
      _fmt(gpsInnovationSigma),
      motionState ?? '',
      zuptEvent ?? '',
      _fmt(zuptDwell),
      mode ?? '',
      stationSnapIndex?.toString() ?? '',
    ].join(',');
  }

  static String _fmt(double? v) {
    if (v == null || v.isNaN || v.isInfinite) return '';
    return v.toStringAsFixed(6);
  }
}

/// Ring buffer telemetry logger for EKF.
///
/// Writes CSV to app documents directory, capped at [maxSizeBytes].
/// When buffer exceeds limit, oldest half of entries are dropped.
///
/// Usage:
/// ```dart
/// final logger = EkfLogger();
/// await logger.startSession();
/// logger.logImu(entry);
/// await logger.endSession();
/// ```
class EkfLogger {
  EkfLogger({this.maxSizeBytes = 10 * 1024 * 1024});

  /// Maximum buffer size before pruning oldest entries.
  final int maxSizeBytes;

  final List<String> _buffer = [];
  int _bufferSizeBytes = 0;
  bool _sessionActive = false;
  File? _currentFile;
  DateTime? _sessionStart;

  /// Enable/disable logging globally (for battery/performance gating).
  bool enabled = true;

  /// Whether a logging session is currently active.
  bool get isActive => _sessionActive;

  /// Current buffer size in bytes.
  int get bufferSizeBytes => _bufferSizeBytes;

  /// Number of entries in buffer.
  int get entryCount => _buffer.length;

  /// Start a new logging session. Creates output file.
  Future<void> startSession() async {
    if (_sessionActive) return;
    _sessionActive = true;
    _sessionStart = DateTime.now();
    _buffer.clear();
    _bufferSizeBytes = 0;

    if (!kIsWeb) {
      try {
        final dir = await getApplicationDocumentsDirectory();
        final logDir = Directory('${dir.path}/ekf_logs');
        if (!await logDir.exists()) {
          await logDir.create(recursive: true);
        }
        final timestamp = _sessionStart!.toIso8601String().replaceAll(':', '-');
        _currentFile = File('${logDir.path}/ekf_$timestamp.csv');
        await _currentFile!.writeAsString('${EkfLogEntry.headerLine()}\n');
      } catch (_) {
        // Fail silently; logging is non-critical.
        _currentFile = null;
      }
    }
  }

  /// Log a telemetry entry.
  void log(EkfLogEntry entry) {
    if (!_sessionActive || !enabled) return;
    final line = entry.toCsvLine();
    _buffer.add(line);
    _bufferSizeBytes += line.length + 1; // +1 for newline

    _maybePrune();
  }

  /// Log a raw IMU sample.
  void logImu({
    required Duration timestamp,
    required double ax,
    required double ay,
    required double az,
    required double gx,
    required double gy,
    required double gz,
    List<double>? gravity,
    List<double>? filteredAccel,
    EkfPublicState? ekfState,
    String? motionState,
    EkfMode? mode,
  }) {
    log(EkfLogEntry(
      monotonicMs: timestamp.inMilliseconds,
      wallClockMs: DateTime.now().millisecondsSinceEpoch,
      imuAx: ax,
      imuAy: ay,
      imuAz: az,
      imuGx: gx,
      imuGy: gy,
      imuGz: gz,
      gravityX: gravity?[0],
      gravityY: gravity?[1],
      gravityZ: gravity?[2],
      filteredAx: filteredAccel?[0],
      filteredAy: filteredAccel?[1],
      filteredAz: filteredAccel?[2],
      ekfS: ekfState?.s,
      ekfV: ekfState?.v,
      ekfBiasA: ekfState?.biasA,
      sigmaS: ekfState?.sigmaS,
      sigmaV: ekfState?.sigmaV,
      motionState: motionState,
      mode: mode?.name,
    ));
  }

  /// Log a GPS update event.
  void logGps({
    required Duration timestamp,
    required double lat,
    required double lng,
    required double accuracy,
    double? innovation,
    double? innovationSigma,
    EkfPublicState? ekfState,
    EkfMode? mode,
  }) {
    log(EkfLogEntry(
      monotonicMs: timestamp.inMilliseconds,
      wallClockMs: DateTime.now().millisecondsSinceEpoch,
      gpsLat: lat,
      gpsLng: lng,
      gpsAccuracy: accuracy,
      gpsInnovation: innovation,
      gpsInnovationSigma: innovationSigma,
      ekfS: ekfState?.s,
      ekfV: ekfState?.v,
      ekfBiasA: ekfState?.biasA,
      sigmaS: ekfState?.sigmaS,
      sigmaV: ekfState?.sigmaV,
      mode: mode?.name,
    ));
  }

  /// Log a ZUPT event.
  void logZupt({
    required Duration timestamp,
    required bool confirmed,
    double? dwellSeconds,
    EkfPublicState? ekfState,
    int? stationSnapIndex,
  }) {
    log(EkfLogEntry(
      monotonicMs: timestamp.inMilliseconds,
      wallClockMs: DateTime.now().millisecondsSinceEpoch,
      zuptEvent: confirmed ? 'confirmed' : 'candidate',
      zuptDwell: dwellSeconds,
      ekfS: ekfState?.s,
      ekfV: ekfState?.v,
      ekfBiasA: ekfState?.biasA,
      sigmaS: ekfState?.sigmaS,
      sigmaV: ekfState?.sigmaV,
      stationSnapIndex: stationSnapIndex,
    ));
  }

  /// End the current session and flush buffer to file.
  Future<void> endSession() async {
    if (!_sessionActive) return;
    _sessionActive = false;

    await _flushToFile();

    _buffer.clear();
    _bufferSizeBytes = 0;
    _currentFile = null;
    _sessionStart = null;
  }

  /// Flush current buffer to file (for periodic saves).
  Future<void> flush() async {
    if (!_sessionActive) return;
    await _flushToFile();
    _buffer.clear();
    _bufferSizeBytes = 0;
  }

  /// Get all EKF log files for export.
  Future<List<File>> getLogFiles() async {
    if (kIsWeb) return [];
    try {
      final dir = await getApplicationDocumentsDirectory();
      final logDir = Directory('${dir.path}/ekf_logs');
      if (!await logDir.exists()) return [];
      final files = <File>[];
      await for (final entity in logDir.list()) {
        if (entity is File && entity.path.endsWith('.csv')) {
          files.add(entity);
        }
      }
      files.sort((a, b) => b.path.compareTo(a.path)); // Newest first
      return files;
    } catch (_) {
      return [];
    }
  }

  /// Delete log files older than [days].
  Future<void> cleanupOldLogs({int days = 7}) async {
    if (kIsWeb) return;
    try {
      final cutoff = DateTime.now().subtract(Duration(days: days));
      final files = await getLogFiles();
      for (final file in files) {
        final stat = await file.stat();
        if (stat.modified.isBefore(cutoff)) {
          await file.delete();
        }
      }
    } catch (_) {
      // Fail silently.
    }
  }

  void _maybePrune() {
    if (_bufferSizeBytes <= maxSizeBytes) return;

    // Drop oldest half.
    final dropCount = _buffer.length ~/ 2;
    if (dropCount == 0) return;

    int bytesToRemove = 0;
    for (int i = 0; i < dropCount; i++) {
      bytesToRemove += _buffer[i].length + 1;
    }
    _buffer.removeRange(0, dropCount);
    _bufferSizeBytes = math.max(0, _bufferSizeBytes - bytesToRemove);
  }

  Future<void> _flushToFile() async {
    if (_currentFile == null || _buffer.isEmpty) return;
    try {
      final content = _buffer.join('\n') + '\n';
      await _currentFile!.writeAsString(content, mode: FileMode.append);
    } catch (_) {
      // Fail silently.
    }
  }
}

/// Global EKF logger instance.
final ekfLogger = EkfLogger();
