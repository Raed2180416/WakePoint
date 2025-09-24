import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/reroute_policy.dart';
import 'package:geowake2/services/trackingservice.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Reroute policy stream continuity after cooldown update', () async {
    // Simulate TrackingService setup that creates a policy once
    TrackingService.isTestMode = true;
  // Access TrackingService just to ensure test-mode path is set; no instance needed beyond this.

    // Build minimal start to initialize background pipeline objects via _onStart path
    // We won't actually start bg isolate here; instead, construct policy and listen directly
    final policy = ReroutePolicy(cooldown: const Duration(milliseconds: 200), initialOnline: true);

    // Listen to its stream and record decisions
    final decisions = <RerouteDecision>[];
    final sub = policy.stream.listen(decisions.add);

    // Fire a sustained deviation -> expect shouldReroute true immediately
    final t0 = DateTime.now();
    policy.onSustainedDeviation(at: t0);
    // Cooldown active now; next within cooldown should be false
    policy.onSustainedDeviation(at: t0.add(const Duration(milliseconds: 50)));

    // Update cooldown in place (mimics TrackingService.startLocationStream)
    policy.setCooldown(const Duration(milliseconds: 50));

    // After cooldown window passes, another deviation should produce true again
    await Future<void>.delayed(const Duration(milliseconds: 80));
    policy.onSustainedDeviation(at: t0.add(const Duration(milliseconds: 200)));

    await Future<void>.delayed(const Duration(milliseconds: 50));
    await sub.cancel();

    // Validate continuity and decisions
    expect(decisions.length, greaterThanOrEqualTo(3));
    // First should be true, second false (cooldown), third true after new cooldown elapsed
    expect(decisions[0].shouldReroute, isTrue);
    expect(decisions[1].shouldReroute, isFalse);
    expect(decisions.last.shouldReroute, isTrue);
  });
}
