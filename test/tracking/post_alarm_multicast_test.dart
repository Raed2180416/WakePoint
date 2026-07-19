// The load-bearing core-safety test: a throwing OR hanging post-alarm listener
// must neither prevent the wake nor block other listeners. dispatch() is the
// tail of the alarm path, so it must return synchronously and never throw.
import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/tracking/post_alarm_multicast.dart';

void main() {
  final m = PostAlarmMulticast.instance;

  setUp(m.clear);
  tearDown(m.clear);

  test('dispatch returns synchronously and never throws even with a bad listener',
      () {
    m.addListener(() => throw StateError('boom'));
    // Must not throw out of dispatch.
    expect(m.dispatch, returnsNormally);
  });

  test('a throwing listener does not starve the others', () async {
    var good = 0;
    m.addListener(() => throw Exception('bad'));
    m.addListener(() => good++);
    m.addListener(() => good++);

    m.dispatch();
    await _pump();

    expect(good, 2);
  });

  test('a hanging (never-completing async) listener does not block others',
      () async {
    var reached = false;
    // Listener kicks off async work that never completes — fire-and-forget.
    m.addListener(() {
      // ignore: unawaited_futures
      Future<void>(() async {
        await Future<void>.delayed(const Duration(days: 1));
      });
    });
    m.addListener(() => reached = true);

    m.dispatch();
    await _pump();

    expect(reached, isTrue);
  });

  test('addListener is idempotent; removeListener works', () {
    void l() {}
    m.addListener(l);
    m.addListener(l);
    expect(m.listenerCount, 1);
    m.removeListener(l);
    expect(m.listenerCount, 0);
  });
}

Future<void> _pump() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
