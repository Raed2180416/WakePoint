// DIAGNOSTIC PROBE (not a gate): instruments the real Majestic underground
// ride to expose WHY the along-track estimate drifts ~1.3 km through the first
// deep tunnel instead of being re-anchored by ZUPT + StationAssociation.
//
// Hypothesis under test (see underground_validation_execution.md):
//   H1 "velocity pinning": GPS is lost ~25 s after boarding, before the EKF has
//      learned cruise velocity. In-tunnel metro cruising is smooth, so the
//      normal ZUPT path (imuQuiet && velocityLow) keeps firing while the train
//      is MOVING, pinning v≈0. The estimate barely advances, σ_s stays small
//      (confidently wrong), so the correct next station is never inside the
//      association window → no snap → error accumulates.
//   H2 "gate starvation": ZUPT fires correctly at real dwells, but the
//      association window/confidence gate rejects the snap.
//
// Skips when the external real fixtures are absent (CI).
//
// ignore_for_file: avoid_print

@Timeout(Duration(minutes: 15))
library;

import 'package:flutter_test/flutter_test.dart';

import 'replay_harness_test.dart';

void main() {
  test('PROBE: Majestic ride — ZUPT/association behaviour inside blind windows',
      () {
    const basename =
        'fixture_Nadaprabhu_Kempegowda_Metro_Station_Majestic-2025-12-21_07-35-32';
    final fixtures = discoverFixtures();
    if (!fixtures.contains(basename)) {
      print('PROBE skipped — real Majestic fixture not present.');
      return;
    }

    final zuptConfirms = <String>[];
    final checks = <String>[];
    final stationLines = <String>[];

    final r = runReplay(basename, onOrchestrator: (orch) {
      orch.logVerbosity = 1; // enables the periodic ZUPT Check log
      orch.onLog = (tag, message, data) {
        if (tag == 'ZUPT' && message.contains('CONFIRMED')) {
          zuptConfirms.add('t=${data?['timestamp']} v=${data?['v']} '
              'src=${data?['source']}');
        } else if (tag == 'ZUPT' && message == 'Check') {
          checks.add('motion=${data?['motion']} v=${data?['v']} '
              'sigmaS=${data?['sigmaS']} accelVar=${data?['accelVar']} '
              'gyroVar=${data?['gyroVar']} imuQuiet=${data?['imuQuiet']} '
              'meetsV=${data?['meetsV']}');
        } else if (tag == 'STATION') {
          stationLines.add('$message ${data ?? ''}');
        }
      };
    });

    print('run: fired=${r.fired} late=${r.isLate} fire=${r.fireTs}s '
        'margin=${r.secondsMargin}s');
    print('');
    print('== ZUPT CONFIRMS (${zuptConfirms.length}) — ground-truth dwells are '
        'near station arrivals: 12.7, 141.9, 342.8, 615.9, 752.3, 916.9, '
        '1236.9, 1405.0, 1524.9, 1665.7, 1943.9, 2160.8, 2253.2 s ==');
    for (final l in zuptConfirms) {
      print('  $l');
    }
    print('');
    print('== ZUPT CHECKS (every ~2s; first 60 lines — covers t≈0..120s, '
        'i.e. the first blind window 25.5–148.8s where drift happens) ==');
    for (final l in checks.take(60)) {
      print('  $l');
    }
    print('');
    print('== STATION ASSOCIATION lines (${stationLines.length}) ==');
    for (final l in stationLines.take(60)) {
      print('  $l');
    }
    expect(r.fired, isTrue);
  });
}
