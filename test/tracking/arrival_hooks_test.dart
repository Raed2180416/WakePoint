// Core-safety tests for ArrivalHooks — the post-arrival fan-out invoked at the
// _finalAlarmActive END TRACKING handler, AFTER completeEndTracking().
//
// The load-bearing property: fireArrived is synchronous, never throws, and can
// never block/delay/abort the never-late wake. It runs strictly after the wake
// is already delivered, but we still prove it is inert toward the caller even
// when a bundled sink (a Guardian post-alarm listener) is hostile.
import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/tracking/arrival_hooks.dart';
import 'package:geowake2/services/tracking/post_alarm_multicast.dart';

void main() {
  final multicast = PostAlarmMulticast.instance;

  setUp(multicast.clear);
  tearDown(multicast.clear);

  test('fireArrived returns synchronously and never throws (bare call)', () {
    expect(() => ArrivalHooks.fireArrived(), returnsNormally);
  });

  test('fireArrived with a full trip descriptor returns normally', () {
    expect(
      () => ArrivalHooks.fireArrived(
        destStation: 'MG Road',
        line: 'Purple Line',
        city: 'Bengaluru',
        destLat: 12.9756,
        destLng: 77.6068,
        originLat: 12.9698,
        originLng: 77.7500,
        mode: 'stops',
        now: DateTime.fromMillisecondsSinceEpoch(1_700_000_000_000),
      ),
      returnsNormally,
    );
  });

  test('a throwing Guardian post-alarm listener cannot break fireArrived', () {
    multicast.addListener(() => throw StateError('guardian boom'));
    expect(() => ArrivalHooks.fireArrived(), returnsNormally);
  });

  test('fireArrived dispatches the post-alarm multicast (Guardian arrived)',
      () async {
    var arrivedFanouts = 0;
    multicast.addListener(() => throw Exception('bad listener')); // hostile
    multicast.addListener(() => arrivedFanouts++);
    multicast.addListener(() => arrivedFanouts++);

    ArrivalHooks.fireArrived(destStation: 'Indiranagar');
    await _pump();

    // The hostile listener did not starve the good ones, and dispatch fired.
    expect(arrivedFanouts, 2);
  });

  test('fireArrived never blocks: it returns before its microtasks drain', () {
    var ran = false;
    multicast.addListener(() => ran = true);

    ArrivalHooks.fireArrived();

    // dispatch() schedules listeners on microtasks; fireArrived has already
    // returned synchronously, so the listener has NOT run yet. Proves the call
    // is non-blocking and does its work off the caller's critical path.
    expect(ran, isFalse);
  });

  test('missing coordinates simply skip the aggregate surface (no throw)', () {
    // Only a destination, no origin -> DataAssetPipeline is not invoked; the
    // rest of the fan-out still runs without error.
    expect(
      () => ArrivalHooks.fireArrived(destLat: 12.97, destLng: 77.60),
      returnsNormally,
    );
  });
}

Future<void> _pump() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
