// lib/services/data_asset/http_candidate_egress_sink.dart
//
// GeoWake — HTTP egress for on-device ReleaseCandidateMatrix payloads.
//
// This sink POSTs the on-device methodology candidate (ReleaseCandidateMatrix)
// to the backend merge engine. The backend then merges across devices, applies
// real cross-device k-anonymity + DP noise, and produces ReleasedCells.
//
// Consent-gated: the pipeline checks consent BEFORE calling this sink.
// Kill-switch: respects kDataAssetEgressEnabled — if false, this sink is a
// no-op (same as NullEgressSink), ensuring no bytes leave the device until
// the flag is explicitly flipped.

import 'dart:convert';
import 'dart:developer' as dev;

import 'package:http/http.dart' as http;
import 'aggregate_schema.dart';
import 'data_asset_config.dart';

/// Upload contract for on-device ReleaseCandidateMatrix payloads.
/// Distinct from [AggregateEgressSink] (which accepts only merge-backend
/// ReleasedCells in an OdFlowMatrix).
abstract class CandidateEgressSink {
  Future<void> uploadCandidate(ReleaseCandidateMatrix candidate);
}

/// No-op sink for when egress is disabled. Transmits nothing.
class NullCandidateEgressSink implements CandidateEgressSink {
  const NullCandidateEgressSink();

  @override
  Future<void> uploadCandidate(ReleaseCandidateMatrix candidate) async {
    // Intentionally empty. Zero bytes leave the device.
  }
}

/// HTTP sink that POSTs ReleaseCandidateMatrix to the backend merge engine.
///
/// Requires [kDataAssetEgressEnabled] to be true AND a valid endpoint URL.
/// If either is missing, the sink degrades to a no-op.
class HttpCandidateEgressSink implements CandidateEgressSink {
  final String _endpoint;
  final String? Function() _tokenProvider;
  final http.Client? _client;

  HttpCandidateEgressSink({
    required String endpoint,
    required String? Function() tokenProvider,
    http.Client? client,
  })  : _endpoint = endpoint,
        _tokenProvider = tokenProvider,
        _client = client;

  @override
  Future<void> uploadCandidate(ReleaseCandidateMatrix candidate) async {
    if (!kDataAssetEgressEnabled || _endpoint.isEmpty) {
      dev.log('HttpCandidateEgressSink: egress disabled or endpoint empty — '
          'skipping upload',
          name: 'HttpCandidateEgressSink');
      return;
    }

    try {
      final token = _tokenProvider();
      final headers = <String, String>{
        'Content-Type': 'application/json',
      };
      if (token != null) {
        headers['Authorization'] = 'Bearer $token';
      }

      final body = jsonEncode(candidate.toJson());
      final client = _client ?? http.Client();

      final response = await client
          .post(
            Uri.parse('$_endpoint/ingest'),
            headers: headers,
            body: body,
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        dev.log(
          'HttpCandidateEgressSink: uploaded ${candidate.cells.length} cells — '
          '${data['cellsReceived'] ?? '?'} received',
          name: 'HttpCandidateEgressSink',
        );
      } else {
        dev.log(
          'HttpCandidateEgressSink: upload failed — HTTP ${response.statusCode}',
          name: 'HttpCandidateEgressSink',
        );
      }
    } catch (e) {
      // Fail-open: egress failure must never influence the alarm path.
      dev.log('HttpCandidateEgressSink: upload error (swallowed): $e',
          name: 'HttpCandidateEgressSink');
    }
  }
}
