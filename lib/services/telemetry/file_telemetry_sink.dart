// lib/services/telemetry/file_telemetry_sink.dart
//
// Durable, fail-open telemetry sink (BACKLOG #7 + #16).
//
// The in-memory ring buffer (InMemoryTelemetrySink) evaporates on process death
// — the exact OS-kill the reliability funnel exists to measure. This sink
// appends each event's toJsonLine() to a JSONL file under a caller-provided
// directory so events survive that kill.
//
// Design constraints, on purpose:
//   * Injectable directory. path_provider (getApplicationSupportDirectory) is
//     resolved by the caller (main.dart) and passed in, so this sink — and the
//     service that registers it — stays a pure-Dart unit testable against
//     Directory.systemTemp with zero plugin dependency.
//   * Bounded RAM buffer, flushed on flush() and automatically every N events,
//     so a long session never grows unbounded before the first durable write.
//   * Size-capped with rotation: the active file is kept at/under maxBytes
//     (default 512 KB) by rotating it to "<file>.1" (single generation) before a
//     write that would exceed the cap. A single event larger than the cap is
//     written anyway (we never drop the data) — the cap is a soft ceiling.
//   * Fail-open, always: every public method swallows its own errors. Telemetry
//     must NEVER throw into the alarm path.

import 'dart:convert';
import 'dart:io';

import 'telemetry_service.dart';

/// A [TelemetrySink] that appends events to a rotating JSONL file.
///
/// Extends [TelemetrySink] so it inherits the interface contract and overrides
/// both [add] (buffered, auto-flushing) and [flush] (durable write).
class FileTelemetrySink extends TelemetrySink {
  FileTelemetrySink({
    required String dir,
    String fileName = 'telemetry.jsonl',
    int flushEveryN = 32,
    int maxBytes = 512 * 1024,
  })  : _dir = dir,
        _fileName = fileName,
        // Clamp to sane minimums so a misconfiguration can't cause a
        // divide-by-nothing flush loop or a zero-cap that rotates every line.
        _flushEveryN = flushEveryN < 1 ? 1 : flushEveryN,
        _maxBytes = maxBytes < 1 ? 1 : maxBytes;

  final String _dir;
  final String _fileName;
  final int _flushEveryN;
  final int _maxBytes;

  // Bounded in-memory buffer of already-serialised JSONL lines. Serialising in
  // add() (not in flush()) keeps flush() cheap and means a bad event is dropped
  // at emit time, not at the durability boundary.
  final List<String> _buffer = <String>[];

  String get _activePath => '$_dir${Platform.pathSeparator}$_fileName';
  String get _rotatedPath => '$_activePath.1';

  @override
  void add(TelemetryEvent event) {
    try {
      _buffer.add(event.toJsonLine());
      if (_buffer.length >= _flushEveryN) {
        _flushSync();
      }
    } catch (_) {/* fail-open: never throw into the caller */}
  }

  @override
  Future<void> flush() async {
    try {
      _flushSync();
    } catch (_) {/* fail-open: a bad disk must never break the caller */}
  }

  // Synchronous durable write. Any throw here is caught by add()/flush(); on a
  // failed write the buffer is intentionally NOT cleared, so the events stay in
  // RAM and a later flush can retry.
  void _flushSync() {
    if (_buffer.isEmpty) return;
    final dir = Directory(_dir);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    final payload = '${_buffer.join('\n')}\n';
    final active = File(_activePath);
    final existing = active.existsSync() ? active.lengthSync() : 0;
    final pending = utf8.encode(payload).length;
    // Rotate before a write that would push a non-empty active file past the
    // cap. (existing == 0 => first write into a fresh file: never rotate, even
    // if this single batch is itself larger than the cap.)
    if (existing > 0 && existing + pending > _maxBytes) {
      _rotate(active);
    }
    // flush:true fsyncs the append so a kill immediately after can't lose it.
    active.writeAsStringSync(payload, mode: FileMode.append, flush: true);
    _buffer.clear();
  }

  void _rotate(File active) {
    try {
      final rotated = File(_rotatedPath);
      if (rotated.existsSync()) rotated.deleteSync();
      active.renameSync(_rotatedPath);
    } catch (_) {
      // Fail-open: if rotation fails we keep appending to the active file rather
      // than losing events. The cap is best-effort.
    }
  }
}
