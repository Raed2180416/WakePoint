// lib/services/data_asset/http_aggregate_egress_sink.dart
//
// GeoWake — the (INERT) HTTP implementation of the egress contract
// (DATA_SURFACE_SPEC §2.9 / §5 Phase B). CLIENT PLUMBING ONLY. SHIPS OFF.
//
// This file exists so the wire format and the transmit path are reviewable and
// testable NOW, without any of it being reachable. It is NOT wired: the pipeline
// default sink is still `NullEgressSink` (see DataAssetPipeline.init, whose
// assert refuses any non-null sink while egress is OFF). Do NOT wire this class
// until ALL of the following are true (business-gated, out of scope here):
//   • kDataAssetEgressEnabled is flipped true, AND
//   • kDataAssetEgressEndpoint points at a live secure-aggregation MERGE
//     backend + ingestion server, AND
//   • a contracted buyer + an Indian DP-lawyer DPIA sign-off exist.
//
// Why it can never transmit today — three independent locks:
//   1. TYPE. `upload` accepts ONLY an [OdFlowMatrix], whose cells are
//      [ReleasedCell]s. A ReleasedCell is constructable solely by the merge
//      backend via `ReleasedCell.fromSecureMerge` (needs a MergeBackendAuthority
//      token no on-device code can mint; R3). No such backend exists, so no
//      OdFlowMatrix of released cells can be produced on-device to hand in.
//   2. FLAG. The first statement of `upload` is a hard `kDataAssetEgressEnabled`
//      gate that returns before constructing any request. While the const is
//      false this is dead code by construction.
//   3. CONFIG. Even past the flag, an empty [kDataAssetEgressEndpoint] short
//      -circuits — there is nowhere to send.
//
// It is also OFF THE ALARM PATH entirely: nothing in the never-late spine
// references egress. This is an observer-side, opt-in, doubly-gated surface.

import 'dart:convert';
import 'dart:developer' as dev;

import 'package:http/http.dart' as http;

import 'aggregate_egress_sink.dart';
import 'aggregate_schema.dart';
import 'data_asset_config.dart';

/// INERT HTTP egress sink. Implements the [AggregateEgressSink] contract so the
/// transmit path is auditable, but it can never send while the egress kill
/// -switch is off and no merge backend can mint a [ReleasedCell]. Never wired as
/// the pipeline default (that stays [NullEgressSink]).
class HttpAggregateEgressSink implements AggregateEgressSink {
  /// Ingestion endpoint. Defaults to the inert [kDataAssetEgressEndpoint]
  /// placeholder (empty ⇒ nowhere to send).
  final String endpoint;

  /// Injectable for tests; defaults to a real client that is only ever
  /// constructed lazily and never used while egress is OFF.
  final http.Client Function() _clientFactory;

  HttpAggregateEgressSink({
    String? endpoint,
    http.Client Function()? clientFactory,
  })  : endpoint = endpoint ?? kDataAssetEgressEndpoint,
        _clientFactory = clientFactory ?? http.Client.new;

  @override
  Future<void> upload(OdFlowMatrix released) async {
    // LOCK 2 — hard flag gate. While kDataAssetEgressEnabled is false (always,
    // today) this returns before any network object is even constructed.
    if (!kDataAssetEgressEnabled) {
      dev.log(
        'HttpAggregateEgressSink.upload called while egress is OFF — no-op.',
        name: 'HttpAggregateEgressSink',
      );
      return;
    }

    // LOCK 3 — no configured destination ⇒ nothing to send.
    if (endpoint.isEmpty) {
      dev.log(
        'HttpAggregateEgressSink.upload has no endpoint configured — no-op.',
        name: 'HttpAggregateEgressSink',
      );
      return;
    }

    // Past all three locks (only reachable in Phase B): POST the released,
    // DP-noised, k-suppressed aggregate. `released` is an OdFlowMatrix of
    // ReleasedCells by type — a coordinate or an un-noised count cannot reach
    // here. Fail-open: a transmit failure is swallowed, never rethrown.
    final client = _clientFactory();
    try {
      final uri = Uri.parse(endpoint);
      final body = jsonEncode(released.toJson());
      await client.post(
        uri,
        headers: const {
          'content-type': 'application/json',
          'x-geowake-schema': kAggregateSchemaVersion,
        },
        body: body,
      );
    } catch (e) {
      dev.log('HttpAggregateEgressSink.upload swallowed: $e',
          name: 'HttpAggregateEgressSink');
    } finally {
      client.close();
    }
  }
}
