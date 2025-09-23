import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/eta_utils.dart';

void main() {
  test('EtaUtils computes remaining time within current step correctly', () {
    final boundaries = [1000.0, 2000.0, 3500.0];
    final durations = [600.0, 900.0, 1200.0]; // 10m, 15m, 20m
    // Progress at 1500m: half of step2 (1000m long -> 900s total), remain 500/1000 * 900 = 450s; plus tail 1200s = 1650s
    final eta = EtaUtils.etaRemainingSeconds(progressMeters: 1500.0, stepBoundariesMeters: boundaries, stepDurationsSeconds: durations);
    expect(eta, closeTo(1650.0, 1e-6));
  });
  test('EtaUtils returns 0 at or past end', () {
    final boundaries = [1000.0, 2000.0];
    final durations = [300.0, 300.0];
    final eta = EtaUtils.etaRemainingSeconds(progressMeters: 2500.0, stepBoundariesMeters: boundaries, stepDurationsSeconds: durations);
    expect(eta, 0.0);
  });
}
