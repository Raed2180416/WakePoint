// lib/core/logging/app_logger.dart
//
// Centralized logging infrastructure for GeoWake.
// Provides structured logging with levels, subsystem tagging, and extensibility
// for future file/remote logging.

import 'dart:developer' as dev;
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Log levels in increasing severity order.
enum LogLevel {
  /// Detailed debugging information (development only)
  debug,

  /// General informational messages
  info,

  /// Warning conditions that don't prevent operation
  warn,

  /// Error conditions that affect functionality
  error,

  /// Fatal errors that require immediate attention
  fatal,
}

/// Centralized logger with subsystem tagging and structured output.
///
/// Usage:
/// ```dart
/// final log = AppLogger('MyService');
/// log.info('Operation completed', data: {'count': 42});
/// log.error('Failed to process', error: e, stack: stackTrace);
/// ```
class AppLogger {
  /// Cache of loggers by name to avoid creating duplicates
  static final Map<String, AppLogger> _loggers = {};

  /// Global log level filter - messages below this level are ignored
  static LogLevel minLevel = kDebugMode ? LogLevel.debug : LogLevel.info;

  /// Enable/disable file logging (for production diagnostics)
  static bool enableFileLogging = false;

  /// File logging instance (lazily initialized)
  static _FileLogger? _fileLogger;

  /// The subsystem name for this logger instance
  final String name;

  AppLogger._(this.name);

  /// Get or create a logger for the given subsystem name.
  factory AppLogger(String name) {
    return _loggers.putIfAbsent(name, () => AppLogger._(name));
  }

  // ============================================================================
  // PUBLIC LOGGING METHODS
  // ============================================================================

  /// Log a debug message (development only, filtered in release).
  void debug(String message, {Object? data}) {
    _log(LogLevel.debug, message, data: data);
  }

  /// Log an informational message.
  void info(String message, {Object? data}) {
    _log(LogLevel.info, message, data: data);
  }

  /// Log a warning message.
  void warn(String message, {Object? data, Object? error}) {
    _log(LogLevel.warn, message, data: data, error: error);
  }

  /// Log an error message with optional exception and stack trace.
  void error(String message, {Object? data, Object? error, StackTrace? stack}) {
    _log(LogLevel.error, message, data: data, error: error, stack: stack);
  }

  /// Log a fatal error (app should not continue normally).
  void fatal(String message, {Object? data, Object? error, StackTrace? stack}) {
    _log(LogLevel.fatal, message, data: data, error: error, stack: stack);
  }

  /// Log the start of a timed operation. Returns a function to call on completion.
  void Function({Object? data}) timedOperation(String operationName) {
    final startTime = DateTime.now();
    debug('$operationName started');

    return ({Object? data}) {
      final duration = DateTime.now().difference(startTime);
      debug(
        '$operationName completed',
        data: {
          'duration_ms': duration.inMilliseconds,
          if (data != null) 'result': data,
        },
      );
    };
  }

  // ============================================================================
  // INTERNAL IMPLEMENTATION
  // ============================================================================

  void _log(
    LogLevel level,
    String message, {
    Object? data,
    Object? error,
    StackTrace? stack,
  }) {
    // Filter by minimum level
    if (level.index < minLevel.index) return;

    final emoji = _levelEmoji(level);
    final timestamp = _formatTimestamp(DateTime.now());
    final dataStr = data != null ? ' | data: $data' : '';

    final fullMessage = '$emoji [$timestamp] $message$dataStr';

    // Console output via dart:developer
    dev.log(
      fullMessage,
      name: name,
      level: _levelValue(level),
      error: error,
      stackTrace: stack,
    );

    // File logging (if enabled)
    if (enableFileLogging && !kIsWeb) {
      _logToFile(level, timestamp, message, data, error, stack);
    }
  }

  String _levelEmoji(LogLevel level) {
    switch (level) {
      case LogLevel.debug:
        return '🔍';
      case LogLevel.info:
        return 'ℹ️';
      case LogLevel.warn:
        return '⚠️';
      case LogLevel.error:
        return '❌';
      case LogLevel.fatal:
        return '💀';
    }
  }

  String _levelName(LogLevel level) {
    switch (level) {
      case LogLevel.debug:
        return 'DEBUG';
      case LogLevel.info:
        return 'INFO';
      case LogLevel.warn:
        return 'WARN';
      case LogLevel.error:
        return 'ERROR';
      case LogLevel.fatal:
        return 'FATAL';
    }
  }

  int _levelValue(LogLevel level) {
    // dart:developer log levels
    switch (level) {
      case LogLevel.debug:
        return 500;
      case LogLevel.info:
        return 800;
      case LogLevel.warn:
        return 900;
      case LogLevel.error:
        return 1000;
      case LogLevel.fatal:
        return 1200;
    }
  }

  String _formatTimestamp(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}:'
        '${dt.second.toString().padLeft(2, '0')}.'
        '${dt.millisecond.toString().padLeft(3, '0')}';
  }

  Future<void> _logToFile(
    LogLevel level,
    String timestamp,
    String message,
    Object? data,
    Object? error,
    StackTrace? stack,
  ) async {
    try {
      _fileLogger ??= await _FileLogger.initialize();
      await _fileLogger!.write(
        '[${_levelName(level)}] [$name] [$timestamp] $message'
        '${data != null ? ' | data: $data' : ''}'
        '${error != null ? ' | error: $error' : ''}'
        '${stack != null ? '\n$stack' : ''}\n',
      );
    } catch (_) {
      // Don't let file logging errors break the app
    }
  }

  // ============================================================================
  // STATIC UTILITIES
  // ============================================================================

  /// Get all log files for diagnostics export.
  static Future<List<File>> getLogFiles() async {
    if (_fileLogger == null) return [];
    return _fileLogger!.getLogFiles();
  }

  /// Clear old log files (keeps last 3 days).
  static Future<void> cleanupOldLogs() async {
    if (_fileLogger == null) return;
    await _fileLogger!.cleanup();
  }
}

/// Internal file logger implementation.
class _FileLogger {
  final Directory logDir;
  File? _currentFile;
  IOSink? _sink;
  DateTime? _currentFileDate;

  _FileLogger._(this.logDir);

  static Future<_FileLogger> initialize() async {
    final appDir = await getApplicationDocumentsDirectory();
    final logDir = Directory('${appDir.path}/logs');
    if (!await logDir.exists()) {
      await logDir.create(recursive: true);
    }
    return _FileLogger._(logDir);
  }

  Future<void> write(String line) async {
    await _ensureCurrentFile();
    _sink?.writeln(line);
  }

  Future<void> _ensureCurrentFile() async {
    final today = DateTime.now();
    final dateStr =
        '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';

    if (_currentFileDate?.day != today.day ||
        _currentFileDate?.month != today.month ||
        _currentFileDate?.year != today.year) {
      await _sink?.flush();
      await _sink?.close();

      _currentFile = File('${logDir.path}/geowake_$dateStr.log');
      _sink = _currentFile!.openWrite(mode: FileMode.append);
      _currentFileDate = today;
    }
  }

  Future<List<File>> getLogFiles() async {
    final files = <File>[];
    await for (final entity in logDir.list()) {
      if (entity is File && entity.path.endsWith('.log')) {
        files.add(entity);
      }
    }
    files.sort((a, b) => b.path.compareTo(a.path)); // Newest first
    return files;
  }

  Future<void> cleanup() async {
    final cutoff = DateTime.now().subtract(const Duration(days: 3));
    await for (final entity in logDir.list()) {
      if (entity is File && entity.path.endsWith('.log')) {
        final stat = await entity.stat();
        if (stat.modified.isBefore(cutoff)) {
          await entity.delete();
        }
      }
    }
  }
}

// ============================================================================
// CONVENIENCE LOGGERS FOR MAJOR SUBSYSTEMS
// ============================================================================
// Use these pre-configured loggers for consistency across the codebase.

/// Logger for GPS and location tracking
final gpsLog = AppLogger('GPS');

/// Logger for tracking service and session management
final trackingLog = AppLogger('Tracking');

/// Logger for alarm evaluation and triggering
final alarmLog = AppLogger('Alarm');

/// Logger for ETA calculations
final etaLog = AppLogger('ETA');

/// Logger for stop counting and transit logic
final stopLog = AppLogger('StopLogic');

/// Logger for route management and caching
final routeLog = AppLogger('Route');

/// Logger for network/API operations
final networkLog = AppLogger('Network');

/// Logger for navigation and UI flow
final navigationLog = AppLogger('Navigation');

/// Logger for notifications
final notificationLog = AppLogger('Notification');

/// Logger for background service IPC
final ipcLog = AppLogger('IPC');

/// Logger for sensor fusion / dead reckoning
final sensorLog = AppLogger('Sensor');

/// Logger for state persistence
final stateLog = AppLogger('State');
