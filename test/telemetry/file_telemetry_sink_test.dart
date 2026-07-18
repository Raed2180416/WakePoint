// Deterministic tests for the durable file telemetry sink (BACKLOG #7 + #16).
//
// Pure Dart: writes to Directory.systemTemp, so it runs headless with no plugin
// dependency. Proves: buffered lines land on disk on flush(), auto-flush every
// N events, content is one valid JSON object per line and PII-free, size-cap
// rotation to .1, and strict fail-open (never throws even when the target is
// unwritable).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/telemetry/telemetry_service.dart';
import 'package:geowake2/services/telemetry/file_telemetry_sink.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('geowake_tel_');
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  // A coordinate-free event, matching the PII-free schema by construction.
  TelemetryEvent ev(int i) => TelemetryEvent(
        type: TelemetryEventType.gpsLost,
        timestampMs: 1000 + i,
        props: {'since_fix_s': i.toDouble()},
      );

  File activeFile() => File('${tmp.path}/telemetry.jsonl');
  File rotatedFile() => File('${tmp.path}/telemetry.jsonl.1');

  test('flush() writes exactly one JSONL line per buffered event', () async {
    // flushEveryN high so nothing auto-flushes: flush() is the only write path.
    final sink = FileTelemetrySink(dir: tmp.path, flushEveryN: 1000);
    for (var i = 0; i < 5; i++) {
      sink.add(ev(i));
    }
    // Buffered only — nothing durable yet.
    expect(activeFile().existsSync(), isFalse);

    await sink.flush();

    expect(activeFile().existsSync(), isTrue);
    final lines = activeFile().readAsStringSync().trim().split('\n');
    expect(lines.length, 5);
    for (var i = 0; i < 5; i++) {
      final m = jsonDecode(lines[i]) as Map<String, dynamic>;
      expect(m['t'], TelemetryEventType.gpsLost);
      expect(m['ts'], 1000 + i);
      expect(m['since_fix_s'], i.toDouble());
    }
  });

  test('auto-flushes every N events without an explicit flush()', () {
    final sink = FileTelemetrySink(dir: tmp.path, flushEveryN: 4);
    for (var i = 0; i < 3; i++) {
      sink.add(ev(i));
    }
    // Below the threshold: still buffered.
    expect(activeFile().existsSync(), isFalse);

    sink.add(ev(3)); // 4th event trips the auto-flush
    expect(activeFile().existsSync(), isTrue);
    expect(activeFile().readAsStringSync().trim().split('\n').length, 4);
  });

  test('persisted content is PII-free (no home paths, no coordinates)', () async {
    final sink = FileTelemetrySink(dir: tmp.path, flushEveryN: 1);
    sink.add(ev(0));
    await sink.flush();
    final text = activeFile().readAsStringSync();
    expect(text, isNot(contains('/home/')));
    expect(text, isNot(contains('/Users/')));
    expect(text, isNot(contains('lat')));
    expect(text, isNot(contains('lng')));
  });

  test('size cap: rotates to .1 and keeps the active file at/under the cap', () {
    // Cap sized so exactly one rotation happens and no events are lost:
    // ~45-byte lines over 50 events (~1656 bytes) exceed the cap once, keeping
    // one .1 generation with the active file at/under the cap.
    const cap = 1500;
    final sink =
        FileTelemetrySink(dir: tmp.path, flushEveryN: 1, maxBytes: cap);
    for (var i = 0; i < 50; i++) {
      sink.add(ev(i));
    }
    // Rotation must have happened, keeping a single .1 generation.
    expect(rotatedFile().existsSync(), isTrue,
        reason: 'active file exceeded the cap so it must have rotated to .1');
    expect(activeFile().existsSync(), isTrue);
    // Active file never grows past the cap (each line is < cap).
    expect(activeFile().lengthSync(), lessThanOrEqualTo(cap));
    // No events were lost across the rotation boundary.
    final total = activeFile().readAsStringSync().trim().split('\n').length +
        rotatedFile().readAsStringSync().trim().split('\n').length;
    expect(total, 50);
  });

  test('fail-open: add()/flush() never throw when the target is unwritable', () async {
    // Point the sink under a path whose parent is a regular FILE, so directory
    // creation must fail on every write.
    final blocker = File('${tmp.path}/not_a_dir');
    blocker.writeAsStringSync('x');
    final sink =
        FileTelemetrySink(dir: '${blocker.path}/sub', flushEveryN: 1);

    expect(() => sink.add(ev(0)), returnsNormally);
    await expectLater(sink.flush(), completes);
    // The unwritable target produced no file, and the caller was never harmed.
    expect(Directory('${blocker.path}/sub').existsSync(), isFalse);
  });

  test('flush() on an empty buffer is a no-op (no file created)', () async {
    final sink = FileTelemetrySink(dir: tmp.path, flushEveryN: 1000);
    await sink.flush();
    expect(activeFile().existsSync(), isFalse);
  });

  test('TelemetryService.configureDefaultSinks wires InMemory + File and '
      'TelemetryService.flush() persists to disk', () async {
    final t = TelemetryService.instance;
    t.nowMs = () => 4242;
    t.setDeviceContext(manufacturer: 'Xiaomi', androidSdkInt: 34);
    t.configureDefaultSinks(dir: tmp.path);

    // In-memory sink is still available for the debug UI / tests.
    expect(t.memorySink, isNotNull);

    t.gpsLost(sinceLastFixSeconds: 12.0);
    await t.flush();

    final lines = activeFile().readAsStringSync().trim().split('\n');
    expect(lines.length, 1);
    final m = jsonDecode(lines.single) as Map<String, dynamic>;
    expect(m['t'], TelemetryEventType.gpsLost);
    expect(m['oem'], 'Xiaomi'); // device context is attached
    expect(m['ts'], 4242);
    // Reset the singleton so sibling telemetry tests see a clean in-memory sink.
    t.configure(sinks: [InMemoryTelemetrySink()], replace: true);
  });
}
