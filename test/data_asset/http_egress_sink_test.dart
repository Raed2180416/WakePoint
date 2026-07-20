// Tripwire tests for the INERT HttpAggregateEgressSink.
//
// The load-bearing property: while kDataAssetEgressEnabled is false (its shipped
// value), upload() transmits nothing — it returns before even constructing an
// HTTP client. We prove it by injecting a client factory that would throw the
// instant it is touched, then asserting it is never touched.
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:geowake2/services/data_asset/aggregate_egress_sink.dart';
import 'package:geowake2/services/data_asset/aggregate_schema.dart';
import 'package:geowake2/services/data_asset/data_asset_config.dart';
import 'package:geowake2/services/data_asset/data_asset_pipeline.dart';
import 'package:geowake2/services/data_asset/http_aggregate_egress_sink.dart';

void main() {
  const emptyReleased = OdFlowMatrix(cells: []);

  test('egress kill-switch is OFF (precondition for every claim below)', () {
    expect(kDataAssetEgressEnabled, isFalse);
  });

  test('upload never constructs an HTTP client while egress is OFF', () async {
    var factoryCalls = 0;
    final sink = HttpAggregateEgressSink(
      endpoint: 'https://example.invalid/ingest',
      clientFactory: () {
        factoryCalls++;
        throw StateError('client must never be built while egress is OFF');
      },
    );

    // Returns normally AND never reaches the network layer.
    await sink.upload(emptyReleased);
    expect(factoryCalls, 0);
  });

  test('upload is a no-op even with a configured endpoint (flag dominates)',
      () async {
    var factoryCalls = 0;
    final sink = HttpAggregateEgressSink(
      endpoint: kDataAssetEgressEndpoint, // '' by default
      clientFactory: () {
        factoryCalls++;
        return http.Client();
      },
    );
    await sink.upload(emptyReleased);
    expect(factoryCalls, 0);
  });

  test('it satisfies the AggregateEgressSink contract (type-level bright line)',
      () {
    // The only payload the contract accepts is an OdFlowMatrix of ReleasedCells;
    // a coordinate or un-noised count is not representable at this boundary.
    final HttpAggregateEgressSink sink = HttpAggregateEgressSink();
    expect(sink, isA<AggregateEgressSink>());
  });

  test('DataAssetPipeline refuses to wire it while egress is OFF (stays Null)',
      () async {
    // init() asserts NullEgressSink-only while the kill-switch is false; the
    // assert throws, is caught fail-open, and the wired sink stays NullEgressSink
    // — the transmitting sink can never become the live default by accident.
    final pipe = DataAssetPipeline.instance;
    await pipe.init(sink: HttpAggregateEgressSink());
    expect(pipe.wiredSink, isA<NullEgressSink>());
  });
}
