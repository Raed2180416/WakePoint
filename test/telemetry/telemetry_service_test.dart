// Deterministic tests for the telemetry funnels (HANDOFF §3).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/telemetry/telemetry_service.dart';

void main() {
  late TelemetryService t;
  late InMemoryTelemetrySink sink;
  int clock = 1000;

  setUp(() {
    t = TelemetryService.instance;
    sink = InMemoryTelemetrySink();
    t.configure(sinks: [sink], replace: true, enabled: true);
    clock = 1000;
    t.nowMs = () => clock;
    t.setDeviceContext(
      manufacturer: 'Xiaomi',
      model: 'Redmi Note 12',
      androidSdkInt: 34,
      appVersion: '1.0.0',
      platform: 'android',
    );
  });

  test('every event carries the device/OEM/version breakdown (HANDOFF §3)', () {
    t.sessionStart(locationPrecise: true, notificationsEnabled: true);
    final e = sink.events.single;
    expect(e.type, TelemetryEventType.sessionStart);
    expect(e.props['oem'], 'Xiaomi');
    expect(e.props['sdk'], 34);
    expect(e.props['app'], '1.0.0');
    // serialises cleanly to a JSONL line
    final decoded = jsonDecode(e.toJsonLine()) as Map<String, dynamic>;
    expect(decoded['t'], TelemetryEventType.sessionStart);
    expect(decoded['ts'], 1000);
  });

  test('alarm-outcome classification: late/on-time/early', () {
    expect(TelemetryService.classifyOutcome(-5.0), AlarmOutcome.late);
    expect(TelemetryService.classifyOutcome(0.0), AlarmOutcome.onTime);
    expect(TelemetryService.classifyOutcome(25.0), AlarmOutcome.onTime);
    expect(TelemetryService.classifyOutcome(120.0), AlarmOutcome.early);
  });

  test('north-star alarm-outcome funnel records margin + fire source', () {
    t.alarmOutcome(
      outcome: AlarmOutcome.early,
      marginSeconds: 42.7,
      gpsLostSeconds: 180.0,
      firedViaReachability: true,
      mode: 'stops',
    );
    final e = sink.events.single;
    expect(e.type, TelemetryEventType.alarmOutcome);
    expect(e.props['outcome'], 'early');
    expect(e.props['margin_s'], 42.7); // rounded to 0.1
    expect(e.props['reach'], true);
  });

  test('NO PII: helpers never accept coordinates; errors scrub home paths', () {
    t.recordError(
      Exception('boom at /home/raed/secret/file.dart line 5'),
      StackTrace.fromString('#0 /Users/alice/app/main.dart:10'),
      fatal: true,
    );
    final e = sink.events.single;
    expect(e.props['fatal'], true);
    expect(e.props['err'].toString(), contains('/~/secret'));
    expect(e.props['err'].toString(), isNot(contains('/home/raed')));
    expect(e.props['stack'].toString(), isNot(contains('/Users/alice')));
  });

  test('reliability funnel + reachability activation are recorded', () {
    t.reliability(fgsSurvived: true, dozeEntered: true, backstopFired: false);
    t.reachabilityActivated(
        dtSeconds: 200, boundMeters: 5600, deadReckonedMeters: 5000);
    expect(sink.countOfType(TelemetryEventType.reliability), 1);
    expect(sink.countOfType(TelemetryEventType.reachability), 1);
    final r = sink.events.last;
    expect(r.props['bound_m'], 5600.0);
  });

  test('ring buffer is bounded (never exhausts memory on a long session)', () {
    final small = InMemoryTelemetrySink(capacity: 10);
    t.configure(sinks: [small], replace: true);
    for (int i = 0; i < 100; i++) {
      t.gpsLost(sinceLastFixSeconds: i.toDouble());
    }
    expect(small.length, 10);
  });

  test('telemetry never throws into the caller even if a sink is broken', () {
    t.configure(sinks: [_ThrowingSink()], replace: true);
    // Must not throw despite the sink raising on every add.
    expect(() => t.sessionStart(), returnsNormally);
    expect(() => t.recordError(Exception('x'), null), returnsNormally);
  });
}

class _ThrowingSink extends TelemetrySink {
  @override
  void add(TelemetryEvent event) => throw StateError('sink down');
}
