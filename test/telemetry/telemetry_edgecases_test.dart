// Edge-case & error-path tests for the on-device telemetry funnels.
//
// Focus (deliberately NOT overlapping telemetry_service_test.dart):
//   * a sink that throws on every add must not break sibling sinks or the caller
//   * ring-buffer eviction is exact under a flood (oldest dropped, newest kept)
//   * PII scrub across /home/<user>, /Users/<user>, nested & path-free strings
//   * NaN/Infinity numeric fields must serialise (jsonEncode) without throwing
//   * classifyOutcome boundaries: -0.0, 0, exactly onTimeWindow, just over
//   * every event carries device context after setDeviceContext
//   * disabling telemetry emits nothing (including the crash path)
//
// For a wake-alarm the cardinal sin is a late/never alarm, so the reliability
// funnel that measures it must never silently corrupt or drop events because of
// a bad sink, a bad clock, or a non-finite number.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/telemetry/telemetry_service.dart';

/// A sink that violates its contract by throwing on EVERY add.
class _AlwaysThrowsSink extends TelemetrySink {
  int calls = 0;
  @override
  void add(TelemetryEvent event) {
    calls++;
    throw StateError('sink permanently down');
  }
}

void main() {
  late TelemetryService t;
  late InMemoryTelemetrySink sink;
  int clock = 5000;

  setUp(() {
    t = TelemetryService.instance;
    sink = InMemoryTelemetrySink();
    // Fully reset the singleton for each test.
    t.configure(sinks: [sink], replace: true, enabled: true);
    clock = 5000;
    t.nowMs = () => clock;
    t.setDeviceContext(
      manufacturer: 'Samsung',
      model: 'SM-G991B',
      androidSdkInt: 33,
      appVersion: '2.3.4',
      platform: 'android',
    );
  });

  // Call one of every funnel entrypoint (finite args) + the crash path.
  void emitOneOfEach() {
    t.sessionStart(locationPrecise: true, notificationsEnabled: false);
    t.alarmArmed(mode: 'stops', value: 3);
    t.gpsLost(sinceLastFixSeconds: 5);
    t.gpsReacquired(blackoutSeconds: 10, driftMeters: 4);
    t.alarmOutcome(outcome: AlarmOutcome.onTime, marginSeconds: 12);
    t.reliability(fgsSurvived: true, dozeEntered: true);
    t.reachabilityActivated(dtSeconds: 1, boundMeters: 2, deadReckonedMeters: 3);
    t.ekfHealth(sigmaSMeters: 1, coldStart: false);
    t.recordError(Exception('boom'), null);
  }

  group('broken sinks must not break siblings or the caller', () {
    test('good sink still receives when a throwing sink is registered FIRST',
        () {
      final good = InMemoryTelemetrySink();
      final bad = _AlwaysThrowsSink();
      t.configure(sinks: [bad, good], replace: true);

      expect(() => t.sessionStart(), returnsNormally);
      expect(bad.calls, 1, reason: 'the bad sink was still attempted');
      expect(good.length, 1, reason: 'a throwing sibling must not starve it');
    });

    test('good sink still receives when a throwing sink is registered LAST', () {
      final good = InMemoryTelemetrySink();
      final bad = _AlwaysThrowsSink();
      t.configure(sinks: [good, bad], replace: true);

      expect(() => t.alarmOutcome(outcome: AlarmOutcome.late), returnsNormally);
      expect(good.length, 1);
      expect(bad.calls, 1);
    });

    test('a throwing sink between two good sinks starves neither', () {
      final a = InMemoryTelemetrySink();
      final b = InMemoryTelemetrySink();
      t.configure(sinks: [a, _AlwaysThrowsSink(), b], replace: true);

      t.gpsLost(sinceLastFixSeconds: 1);
      expect(a.length, 1);
      expect(b.length, 1);
    });

    test('caller never throws for ANY funnel even when the only sink throws', () {
      t.configure(sinks: [_AlwaysThrowsSink()], replace: true);
      expect(emitOneOfEach, returnsNormally);
    });

    test('memorySink is null when no in-memory sink is configured', () {
      t.configure(sinks: [_AlwaysThrowsSink()], replace: true);
      expect(t.memorySink, isNull);
    });

    test('telemetry never throws even if the clock injector throws', () {
      t.nowMs = () => throw StateError('clock broken');
      // The outer try/catch in _emit must swallow this; nothing is emitted.
      expect(emitOneOfEach, returnsNormally);
      expect(sink.length, 0, reason: 'a broken clock yields no events, no crash');
    });
  });

  group('ring buffer eviction is exact under a flood', () {
    List<Object?> valuesOf(InMemoryTelemetrySink s) =>
        s.events.map((e) => e.props['value']).toList();

    test('exactly capacity retained; oldest dropped, newest kept', () {
      final s = InMemoryTelemetrySink(capacity: 8);
      t.configure(sinks: [s], replace: true);
      for (int i = 0; i < 25; i++) {
        t.alarmArmed(mode: 'm', value: i); // value passes through verbatim
      }
      expect(s.length, 8);
      // Last 8 of 0..24 == 17..24, in insertion order (oldest first).
      expect(valuesOf(s), [17, 18, 19, 20, 21, 22, 23, 24]);
    });

    test('boundary: exactly-capacity keeps oldest; one more evicts it', () {
      final s = InMemoryTelemetrySink(capacity: 5);
      t.configure(sinks: [s], replace: true);
      for (int i = 0; i < 5; i++) {
        t.alarmArmed(mode: 'm', value: i);
      }
      expect(s.length, 5);
      expect(valuesOf(s), [0, 1, 2, 3, 4]); // oldest (0) still present

      t.alarmArmed(mode: 'm', value: 5); // sixth
      expect(s.length, 5);
      expect(valuesOf(s), [1, 2, 3, 4, 5]); // oldest (0) evicted
    });

    test('capacity 1 keeps only the most recent event', () {
      final s = InMemoryTelemetrySink(capacity: 1);
      t.configure(sinks: [s], replace: true);
      t.alarmArmed(mode: 'm', value: 100);
      t.alarmArmed(mode: 'm', value: 200);
      expect(s.length, 1);
      expect(valuesOf(s), [200]);
    });

    test('capacity 0 retains nothing and does not throw', () {
      final s = InMemoryTelemetrySink(capacity: 0);
      // Exercise the sink directly so the service try/catch cannot mask a throw.
      const ev = TelemetryEvent(type: 'x', timestampMs: 1, props: {});
      expect(() => s.add(ev), returnsNormally);
      expect(s.length, 0);
    });

    test('negative capacity: add must not throw (sinks must not throw)', () {
      // SUSPECTED DEFECT: `while (_buf.length > capacity) removeFirst()` has no
      // emptiness guard, so capacity < 0 calls removeFirst() on an empty queue
      // and throws StateError, violating the "Implementations must not throw"
      // contract on TelemetrySink.
      final s = InMemoryTelemetrySink(capacity: -1);
      const ev = TelemetryEvent(type: 'x', timestampMs: 1, props: {});
      expect(() => s.add(ev), returnsNormally);
    });
  });

  group('PII scrub of error/stack strings', () {
    test('/home/<user> and /Users/<user> nested occurrences are all scrubbed',
        () {
      t.recordError(
        Exception('log at /home/bob/app and /Users/carol/lib done'),
        null,
      );
      final err = t.memorySink!.events.single.props['err'] as String;
      expect(err, contains('/~/app'));
      expect(err, contains('/~/lib'));
      expect(err, isNot(contains('/home/bob')));
      expect(err, isNot(contains('/Users/carol')));
      expect(err, isNot(contains('bob')));
      expect(err, isNot(contains('carol')));
    });

    test('a trailing /home/<user> with no suffix is still scrubbed', () {
      t.recordError(Exception('crashed in /home/raed'), null);
      final err = t.memorySink!.events.single.props['err'] as String;
      expect(err, isNot(contains('raed')));
      expect(err, endsWith('/~'));
    });

    test('a string with no absolute path is left unchanged', () {
      t.recordError(Exception('database timeout after 30s'), null);
      final err = t.memorySink!.events.single.props['err'] as String;
      expect(err, 'Exception: database timeout after 30s');
    });

    test('non home/Users slashes are not touched (e.g. "5/10")', () {
      t.recordError(Exception('progress 5/10 done'), null);
      final err = t.memorySink!.events.single.props['err'] as String;
      expect(err, 'Exception: progress 5/10 done');
    });

    test('long err is scrubbed BEFORE truncation to 300 (no username survives)',
        () {
      // Username sits at the front; scrub removes it, then the tail is cut.
      t.recordError(Exception('/home/raed/${'A' * 400}'), null);
      final err = t.memorySink!.events.single.props['err'] as String;
      expect(err.length, 300);
      expect(err, isNot(contains('raed')));
      expect(err, isNot(contains('/home')));
      expect(err, startsWith('Exception: /~/'));
    });

    test('long stack is scrubbed and truncated to 1200', () {
      t.recordError(
        Exception('x'),
        StackTrace.fromString('/home/raed/${'S' * 2000}'),
      );
      final stack = t.memorySink!.events.single.props['stack'] as String;
      expect(stack.length, 1200);
      expect(stack, isNot(contains('raed')));
    });
  });

  group('NaN / Infinity numeric fields serialise without throwing', () {
    test('rounded funnel fields sanitise non-finite input to 0.0', () {
      t.gpsLost(sinceLastFixSeconds: double.nan);
      t.gpsReacquired(
        blackoutSeconds: double.infinity,
        driftMeters: double.negativeInfinity,
      );
      t.alarmOutcome(
        outcome: AlarmOutcome.late,
        marginSeconds: double.nan,
        gpsLostSeconds: double.infinity,
      );
      t.ekfHealth(sigmaSMeters: double.negativeInfinity, sigmaVMps: double.nan);
      t.reachabilityActivated(
        dtSeconds: double.nan,
        boundMeters: double.infinity,
        deadReckonedMeters: double.nan,
      );

      for (final e in sink.events) {
        // Every non-finite input became a finite 0.0, so JSONL never throws.
        expect(() => e.toJsonLine(), returnsNormally,
            reason: '${e.type} must serialise');
        final decoded = jsonDecode(e.toJsonLine()) as Map<String, dynamic>;
        for (final entry in decoded.entries) {
          if (entry.value is num) {
            expect((entry.value as num).isFinite, isTrue,
                reason: '${e.type}.${entry.key} must be finite after sanitise');
          }
        }
      }
      expect(sink.events.first.props['since_fix_s'], 0.0);
      expect(sink.events[1].props['blackout_s'], 0.0);
      expect(sink.events[1].props['drift_m'], 0.0);
    });

    test('alarmArmed NaN value must still serialise (SUSPECTED DEFECT)', () {
      // `alarmArmed` writes `value` verbatim, bypassing _round(); a NaN here
      // reaches props and jsonEncode() throws JsonUnsupportedObjectError.
      // The safe contract is that a telemetry line never throws on serialise.
      t.alarmArmed(mode: 'gps', value: double.nan);
      final e = sink.events.single;
      expect(() => e.toJsonLine(), returnsNormally);
    });

    test('alarmArmed Infinity value must still serialise (SUSPECTED DEFECT)', () {
      t.alarmArmed(mode: 'gps', value: double.infinity);
      final e = sink.events.single;
      expect(() => e.toJsonLine(), returnsNormally);
    });

    test('finite alarmArmed value is preserved verbatim (incl. negative)', () {
      t.alarmArmed(mode: 'radius', value: -12.5);
      final e = sink.events.single;
      expect(e.props['value'], -12.5);
      expect(() => e.toJsonLine(), returnsNormally);
    });
  });

  group('classifyOutcome boundaries', () {
    test('-0.0 lead is on-time, never late (IEEE754: -0.0 < 0 is false)', () {
      expect(TelemetryService.classifyOutcome(-0.0), AlarmOutcome.onTime);
    });

    test('exactly 0 lead is on-time', () {
      expect(TelemetryService.classifyOutcome(0.0), AlarmOutcome.onTime);
    });

    test('exactly at onTimeWindow is on-time (inclusive upper bound)', () {
      expect(TelemetryService.classifyOutcome(30.0), AlarmOutcome.onTime);
      expect(TelemetryService.classifyOutcome(10.0, onTimeWindow: 10.0),
          AlarmOutcome.onTime);
    });

    test('just over onTimeWindow is early', () {
      expect(TelemetryService.classifyOutcome(30.0 + 1e-6), AlarmOutcome.early);
      expect(TelemetryService.classifyOutcome(10.0 + 1e-6, onTimeWindow: 10.0),
          AlarmOutcome.early);
    });

    test('any negative lead is late (the product-death bucket)', () {
      expect(TelemetryService.classifyOutcome(-1e-9), AlarmOutcome.late);
      expect(TelemetryService.classifyOutcome(-0.1), AlarmOutcome.late);
      expect(TelemetryService.classifyOutcome(double.negativeInfinity),
          AlarmOutcome.late);
    });

    test('non-finite positive-ish leads fall through to early (documented)', () {
      // NaN and +Infinity both fail `< 0` and `<= window`, so they land in
      // `early`. Harmless for firing (this only labels past events) but note it
      // masks unknown/garbage margins as the "safe" bucket in analytics.
      expect(TelemetryService.classifyOutcome(double.nan), AlarmOutcome.early);
      expect(TelemetryService.classifyOutcome(double.infinity),
          AlarmOutcome.early);
    });
  });

  group('device context is attached to every event', () {
    test('all funnel event types carry oem/model/sdk/app/plat', () {
      emitOneOfEach();
      expect(sink.length, 9);
      for (final e in sink.events) {
        expect(e.props['oem'], 'Samsung', reason: '${e.type} missing oem');
        expect(e.props['model'], 'SM-G991B');
        expect(e.props['sdk'], 33);
        expect(e.props['app'], '2.3.4');
        expect(e.props['plat'], 'android');
      }
    });

    test('setDeviceContext REPLACES; stale keys do not linger', () {
      // New context has only 2 of 5 fields.
      t.setDeviceContext(manufacturer: 'Google', androidSdkInt: 30);
      t.sessionStart();
      final e = sink.events.single;
      expect(e.props['oem'], 'Google');
      expect(e.props['sdk'], 30);
      expect(e.props.containsKey('model'), isFalse,
          reason: 'previous model must not persist');
      expect(e.props.containsKey('app'), isFalse);
      expect(e.props.containsKey('plat'), isFalse);
    });

    test('setDeviceContext() with no args clears context; events still emit',
        () {
      t.setDeviceContext();
      t.sessionStart();
      final e = sink.events.single;
      expect(e.props.containsKey('oem'), isFalse);
      expect(e.props.containsKey('sdk'), isFalse);
      expect(e.props.isEmpty, isTrue); // sessionStart() had no args either
      expect(() => e.toJsonLine(), returnsNormally);
    });

    test('toJson carries type/timestamp alongside merged props', () {
      clock = 987654;
      t.gpsLost(sinceLastFixSeconds: 7);
      final json = jsonDecode(sink.events.single.toJsonLine())
          as Map<String, dynamic>;
      expect(json['t'], TelemetryEventType.gpsLost);
      expect(json['ts'], 987654);
      expect(json['oem'], 'Samsung');
      expect(json['since_fix_s'], 7.0);
    });
  });

  group('disabling telemetry emits nothing', () {
    test('no funnel (nor the crash path) emits while disabled', () {
      t.configure(enabled: false);
      expect(emitOneOfEach, returnsNormally);
      expect(sink.length, 0);
    });

    test('re-enabling resumes emission', () {
      t.configure(enabled: false);
      t.sessionStart();
      expect(sink.length, 0);

      t.configure(enabled: true);
      t.sessionStart();
      expect(sink.length, 1);
    });

    test('disabling leaves sinks intact (enabled toggles independently)', () {
      // Disabling without a sinks arg must not clear/replace the sinks.
      t.configure(enabled: false);
      expect(t.memorySink, same(sink));
      t.configure(enabled: true);
      t.gpsLost(sinceLastFixSeconds: 1);
      expect(sink.length, 1);
    });
  });
}
