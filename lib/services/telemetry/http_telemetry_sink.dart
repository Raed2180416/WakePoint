// lib/services/telemetry/http_telemetry_sink.dart
//
// INERT-by-default network egress for telemetry (HANDOFF §3: a reliability app
// eventually needs its funnels off-device to learn which phones fail). Today
// telemetry is PII-free + local JSONL only; this sink lets the same PII-free
// event stream flow to a founder-supplied backend once an endpoint is configured
// via --dart-define.
//
// Design constraints, on purpose:
//   * INERT until configured. An EMPTY endpoint => the sink is a hard no-op:
//     add()/flush() do nothing and no HttpClient is ever touched. Nothing ships
//     off-device until the founder supplies GEOWAKE_TELEMETRY_URL. See
//     businessGated: the actual telemetry server + token are OFF by default.
//   * PII-free by construction. This sink serialises nothing itself — it only
//     forwards event.toJsonLine(), the exact same coordinate-free schema the
//     file sink already persists. It cannot add a lat/lng it never sees.
//   * Batched + bounded. Events accumulate into a buffer and POST as one
//     newline-delimited-JSON body when the buffer reaches [maxBatch] (or on
//     flush()). The buffer is capped so a long offline stretch can never grow
//     RAM without bound — oldest lines are dropped past the cap.
//   * Fail-open, always. Every method swallows its own errors and NEVER throws
//     into the caller. A network failure re-queues the batch (bounded) for a
//     later flush; telemetry must never throw or hang the alarm path.
//
// Uses package:http (already a dependency) so a fake/mock Client injects cleanly
// for deterministic tests.

import 'dart:async';

import 'package:http/http.dart' as http;

import 'telemetry_service.dart';

/// A [TelemetrySink] that batches events and POSTs them as newline-delimited
/// JSON to a configured HTTP endpoint with an optional bearer token.
///
/// Extends [TelemetrySink] so it inherits the interface contract and overrides
/// both [add] (buffered, auto-posting at [maxBatch]) and [flush] (POST now).
class HttpTelemetrySink extends TelemetrySink {
  HttpTelemetrySink({
    required String endpoint,
    String token = '',
    int maxBatch = 50,
    int? maxBuffer,
    http.Client? client,
  })  : _endpoint = endpoint.trim(),
        _token = token.trim(),
        // Clamp so a misconfiguration can't post on every single event or refuse
        // to ever post.
        _maxBatch = maxBatch < 1 ? 1 : maxBatch,
        // Cap the backlog at a few batches so a long offline stretch can't grow
        // RAM without bound; default to 4x the batch size.
        _maxBuffer =
            (maxBuffer ?? (maxBatch < 1 ? 1 : maxBatch) * 4) < 1
                ? 1
                : (maxBuffer ?? (maxBatch < 1 ? 1 : maxBatch) * 4),
        _client = client ?? http.Client();

  final String _endpoint;
  final String _token;
  final int _maxBatch;
  final int _maxBuffer;
  final http.Client _client;

  // Bounded buffer of already-serialised JSONL lines. Serialising in add() keeps
  // the POST body assembly cheap and drops a bad event at emit time.
  final List<String> _buffer = <String>[];

  // True only once configured. An empty endpoint makes the whole sink inert.
  bool get _enabled => _endpoint.isNotEmpty;

  @override
  void add(TelemetryEvent event) {
    if (!_enabled) return;
    try {
      _buffer.add(event.toJsonLine());
      _trim();
      if (_buffer.length >= _maxBatch) {
        // Fire-and-forget: the network POST must never block or throw into the
        // caller. flush() (or the next batch) still drains what this leaves.
        unawaited(_post());
      }
    } catch (_) {/* fail-open: never throw into the caller */}
  }

  @override
  Future<void> flush() async {
    if (!_enabled) return;
    try {
      await _post();
    } catch (_) {/* fail-open: a bad network must never break the caller */}
  }

  // Drop oldest lines once the backlog exceeds the cap (bounded RAM).
  void _trim() {
    while (_buffer.length > _maxBuffer) {
      _buffer.removeAt(0);
    }
  }

  // Snapshot-and-clear, then POST. On a network/server failure the batch is
  // re-queued (front) for a later flush retry, then re-trimmed so the backlog
  // stays bounded. Any throw is contained here.
  Future<void> _post() async {
    if (_buffer.isEmpty) return;
    final batch = List<String>.from(_buffer);
    _buffer.clear();
    try {
      final resp = await _client.post(
        Uri.parse(_endpoint),
        headers: <String, String>{
          'content-type': 'application/x-ndjson',
          if (_token.isNotEmpty) 'authorization': 'Bearer $_token',
        },
        body: '${batch.join('\n')}\n',
      );
      // 5xx is retryable (transient server trouble): re-queue for a later flush.
      // 2xx/4xx are terminal for this batch — dropping a rejected batch is fine
      // for best-effort telemetry and keeps the backlog from wedging.
      if (resp.statusCode >= 500) {
        _buffer.insertAll(0, batch);
        _trim();
      }
    } catch (_) {
      // Network failure (offline, DNS, timeout, bad URL): re-queue, bounded.
      _buffer.insertAll(0, batch);
      _trim();
    }
  }
}
