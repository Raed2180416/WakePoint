// Deterministic tests for the INERT-by-default HTTP telemetry egress sink.
//
// Pure Dart: injects a fake http.Client (package:http/testing.dart MockClient)
// so nothing hits the network. Proves: an empty endpoint is a hard no-op (no
// request ever made), events batch and POST as newline-delimited JSON with the
// bearer header, flush() drains a partial batch, the body is PII-free, and the
// sink is strictly fail-open (never throws even when the client throws or 5xxs).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:geowake2/services/telemetry/telemetry_service.dart';
import 'package:geowake2/services/telemetry/http_telemetry_sink.dart';

void main() {
  // A coordinate-free event, matching the PII-free schema by construction.
  TelemetryEvent ev(int i) => TelemetryEvent(
        type: TelemetryEventType.gpsLost,
        timestampMs: 1000 + i,
        props: {'since_fix_s': i.toDouble()},
      );

  test('empty endpoint is a hard no-op: no request is ever made', () async {
    var calls = 0;
    final client = MockClient((req) async {
      calls++;
      return http.Response('', 200);
    });
    final sink =
        HttpTelemetrySink(endpoint: '', client: client, maxBatch: 1);

    for (var i = 0; i < 5; i++) {
      sink.add(ev(i));
    }
    await sink.flush();

    expect(calls, 0, reason: 'an empty endpoint must never touch the network');
  });

  test('whitespace-only endpoint is also inert', () async {
    var calls = 0;
    final client = MockClient((req) async {
      calls++;
      return http.Response('', 200);
    });
    final sink =
        HttpTelemetrySink(endpoint: '   ', client: client, maxBatch: 1);
    sink.add(ev(0));
    await sink.flush();
    expect(calls, 0);
  });

  test('auto-POSTs one newline-delimited-JSON batch at maxBatch', () async {
    final bodies = <String>[];
    final headers = <Map<String, String>>[];
    final client = MockClient((req) async {
      bodies.add(req.body);
      headers.add(req.headers);
      return http.Response('', 200);
    });
    final sink = HttpTelemetrySink(
      endpoint: 'https://example.test/ingest',
      token: 'secret-abc',
      client: client,
      maxBatch: 3,
    );

    sink.add(ev(0));
    sink.add(ev(1));
    // Below the batch threshold: nothing posted yet.
    expect(bodies, isEmpty);

    sink.add(ev(2)); // 3rd event trips the batch POST
    // add() fires the POST unawaited; let the microtask/async POST settle.
    await Future<void>.delayed(Duration.zero);

    expect(bodies.length, 1);
    final lines = bodies.single.trim().split('\n');
    expect(lines.length, 3);
    for (var i = 0; i < 3; i++) {
      final m = jsonDecode(lines[i]) as Map<String, dynamic>;
      expect(m['t'], TelemetryEventType.gpsLost);
      expect(m['ts'], 1000 + i);
      expect(m['since_fix_s'], i.toDouble());
    }
    // Bearer token + ndjson content-type present.
    expect(headers.single['authorization'], 'Bearer secret-abc');
    expect(headers.single['content-type'], contains('ndjson'));
  });

  test('no token => no authorization header', () async {
    Map<String, String>? seen;
    final client = MockClient((req) async {
      seen = req.headers;
      return http.Response('', 200);
    });
    final sink = HttpTelemetrySink(
      endpoint: 'https://example.test/ingest',
      client: client,
      maxBatch: 1,
    );
    sink.add(ev(0));
    await Future<void>.delayed(Duration.zero);
    expect(seen, isNotNull);
    expect(seen!.containsKey('authorization'), isFalse);
  });

  test('flush() drains a partial (sub-maxBatch) buffer', () async {
    final bodies = <String>[];
    final client = MockClient((req) async {
      bodies.add(req.body);
      return http.Response('', 200);
    });
    final sink = HttpTelemetrySink(
      endpoint: 'https://example.test/ingest',
      client: client,
      maxBatch: 100, // never auto-posts in this test
    );
    sink.add(ev(0));
    sink.add(ev(1));
    expect(bodies, isEmpty);

    await sink.flush();

    expect(bodies.length, 1);
    expect(bodies.single.trim().split('\n').length, 2);

    // A second flush with nothing buffered is a no-op (no empty POST).
    await sink.flush();
    expect(bodies.length, 1);
  });

  test('POST body is PII-free (no home paths, no coordinates)', () async {
    String? body;
    final client = MockClient((req) async {
      body = req.body;
      return http.Response('', 200);
    });
    final sink = HttpTelemetrySink(
      endpoint: 'https://example.test/ingest',
      client: client,
      maxBatch: 1,
    );
    sink.add(ev(0));
    await Future<void>.delayed(Duration.zero);
    expect(body, isNotNull);
    expect(body, isNot(contains('/home/')));
    expect(body, isNot(contains('/Users/')));
    expect(body, isNot(contains('lat')));
    expect(body, isNot(contains('lng')));
  });

  test('fail-open: a throwing client never throws into the caller', () async {
    final client = MockClient((req) async {
      throw const HttpFailure('network down');
    });
    final sink = HttpTelemetrySink(
      endpoint: 'https://example.test/ingest',
      client: client,
      maxBatch: 1,
    );
    expect(() => sink.add(ev(0)), returnsNormally);
    await expectLater(sink.flush(), completes);
  });

  test('5xx re-queues the batch; a later flush retries it', () async {
    var attempt = 0;
    final bodies = <String>[];
    final client = MockClient((req) async {
      attempt++;
      bodies.add(req.body);
      // Fail the first attempt (503), succeed the second.
      return http.Response('', attempt == 1 ? 503 : 200);
    });
    final sink = HttpTelemetrySink(
      endpoint: 'https://example.test/ingest',
      client: client,
      maxBatch: 100,
    );
    sink.add(ev(0));
    await sink.flush(); // attempt 1 -> 503, re-queued
    expect(attempt, 1);

    await sink.flush(); // attempt 2 -> 200, drained
    expect(attempt, 2);
    // Same batch content retried, not lost.
    expect(bodies.last.trim().split('\n').length, 1);

    // Now empty: no further POSTs.
    await sink.flush();
    expect(attempt, 2);
  });

  test('backlog is bounded: oldest lines drop past the buffer cap', () async {
    // The client fails (500) while `fail` is set — nothing drains, so the buffer
    // would grow unbounded without the cap — then succeeds once, letting us read
    // back exactly what survived.
    var fail = true;
    String? drained;
    final client = MockClient((req) async {
      if (fail) return http.Response('', 500);
      drained = req.body;
      return http.Response('', 200);
    });
    final sink = HttpTelemetrySink(
      endpoint: 'https://example.test/ingest',
      client: client,
      maxBatch: 2,
      maxBuffer: 3,
    );
    // Push far more than the cap while every POST fails.
    for (var i = 0; i < 50; i++) {
      sink.add(ev(i));
      await Future<void>.delayed(Duration.zero);
    }
    // Let the last unawaited failing POST settle before the draining flush.
    await sink.flush();

    // Now allow a drain and read what survived: at most the cap, and it is the
    // MOST RECENT events (oldest were dropped).
    fail = false;
    await sink.flush();
    expect(drained, isNotNull);
    final lines = drained!.trim().split('\n');
    expect(lines.length, lessThanOrEqualTo(3),
        reason: 'buffer must stay at/under maxBuffer');
    final last = jsonDecode(lines.last) as Map<String, dynamic>;
    expect(last['ts'], 1000 + 49, reason: 'newest event is retained');
  });
}

/// A trivial exception type so the throwing-client test throws something
/// concrete (rather than a String) from the mock.
class HttpFailure implements Exception {
  final String message;
  const HttpFailure(this.message);
  @override
  String toString() => 'HttpFailure: $message';
}
