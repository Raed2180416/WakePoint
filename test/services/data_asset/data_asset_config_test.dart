// Regression test: the candidate egress endpoint must default to EMPTY
// ('' = inert; HttpCandidateEgressSink no-ops on an empty endpoint) unless
// explicitly supplied at build time via
// --dart-define=GEOWAKE_CANDIDATE_EGRESS_ENDPOINT=..., mirroring
// GEOWAKE_TELEMETRY_URL in main.dart.
//
// BUG (fixed): kCandidateEgressEndpoint was a hardcoded literal pointing at a
// live production Railway URL, relying solely on the runtime
// kDataAssetEgressEnabled flag (plus consent-gating) to stay inert. This test
// runs with no --dart-define passed (the default `flutter test` invocation,
// same as CI), so it fails if the constant regresses back to a hardcoded
// non-empty URL.

import 'package:flutter_test/flutter_test.dart';

import 'package:geowake2/services/data_asset/data_asset_config.dart';

void main() {
  test(
      'kCandidateEgressEndpoint defaults to empty (inert) when no '
      '--dart-define is supplied', () {
    expect(kCandidateEgressEndpoint, isEmpty);
  });

  test('the egress kill-switch stays off regardless of the endpoint default',
      () {
    // Defense-in-depth is layered, not either/or: the compile-time flag must
    // independently stay false.
    expect(kDataAssetEgressEnabled, isFalse);
  });
}
