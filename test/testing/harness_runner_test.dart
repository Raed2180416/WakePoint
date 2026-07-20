// Smoke + contract test for the §7.3 headless scenario harness
// (lib/testing/harness_runner.dart) and, transitively, the §7.2 arbitrary-trip
// EKF synthesis (EkfTestController.loadRouteFromPolyline / ImuReplayEngineV2.
// loadFromPolyline). harness_runner cannot run under plain `dart run` because it
// transitively imports package:flutter (google_maps_flutter + the EKF stack), so
// the CLI entry point IS `flutter test` — this file is that entry point and also
// asserts runScenario produces valid never-late metrics for an arbitrary polyline.

import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/testing/harness_runner.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('runScenario drives an arbitrary polyline end-to-end and returns '
      'never-late metrics (§7.2 + §7.3)', () async {
    // A short synthetic trip as a raw polyline (Bengaluru-ish coords), a couple
    // of stops, a GPS-blackout window, warped so it plays fast.
    final spec = <String, dynamic>{
      // `route` is the polyline array directly (or a named-route string).
      'route': [
        [12.9760, 77.5710],
        [12.9700, 77.5760],
        [12.9640, 77.5810],
        [12.9585, 77.5868],
      ],
      'stops': [
        [12.9700, 77.5760],
        [12.9640, 77.5810],
      ],
      'speedMps': 14.0,
      'warpFactor': 200.0,
      'gpsDropout': {'windows': [[20.0, 45.0]]},
      'alarm': {'mode': 'stops', 'value': 1},
    };

    final m = await runScenario(spec);

    // Contract: the documented metric keys are present and well-typed.
    expect(m, isA<Map<String, dynamic>>());
    expect(m.containsKey('fired'), isTrue,
        reason: 'metrics must report whether the alarm fired: $m');
    expect(m.containsKey('neverLate'), isTrue,
        reason: 'the never-late verdict is the whole point: $m');
    // The synthesized trip must at least run to completion (non-negative time).
    final ran = (m['ranSeconds'] as num?)?.toDouble() ?? -1.0;
    expect(ran, greaterThanOrEqualTo(0.0), reason: 'ranSeconds invalid: $m');

    // NEVER-LATE: if it fired, it must not be a late fire. (neverLate is the
    // harness's own verdict; a false here on a synthetic trip is a real signal.)
    if (m['fired'] == true) {
      expect(m['neverLate'], isTrue,
          reason: 'harness reported a LATE fire on a synthetic polyline: $m');
    }
    // Surface the metrics for the CLI-sweep use case.
    // ignore: avoid_print
    print('harness_runner metrics: $m');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
