// Proof for GAP #8: the alarmOutcome emit SITE fires on a real destination-alarm
// trigger, and correctly infers the fire lever (reachability vs statistical) and
// mode from the fire reason. The persisted sink + the typed emit methods are
// proven in the other telemetry tests; this proves the WIRING at the fire path.

import 'package:flutter_test/flutter_test.dart';

import 'package:geowake2/services/tracking/alarm_controller.dart';
import 'package:geowake2/services/telemetry/telemetry_service.dart';
import 'package:geowake2/services/test_service_instance.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late InMemoryTelemetrySink sink;
  setUp(() {
    sink = InMemoryTelemetrySink();
    TelemetryService.instance
        .configure(sinks: [sink], replace: true, enabled: true);
  });

  Future<void> fire(String reason) async {
    final ac = AlarmController();
    try {
      await ac.triggerAlarmNotification(
        service: TestServiceInstance(),
        title: 'Wake Up!',
        body: 'x',
        allowContinueTracking: false,
        isBackgroundIsolate: false,
        isTestMode: true,
        debugReason: reason,
      );
    } catch (_) {/* the emit is before any notification I/O */}
  }

  test('cold-start reachability fire => alarmOutcome{reach:true}', () async {
    await fire('Cold-start reachability backstop (s_max=1000m >= target 800m)');
    expect(sink.countOfType(TelemetryEventType.alarmOutcome), 1);
    final e = sink.events
        .firstWhere((e) => e.type == TelemetryEventType.alarmOutcome);
    expect(e.props['reach'], true);
    expect(e.props['outcome'], 'onTime');
  });

  test('distance-mode fire => alarmOutcome{mode:distance, reach:false}',
      () async {
    await fire('Distance-mode destination (remaining 0.90km <= 1)');
    final e = sink.events
        .firstWhere((e) => e.type == TelemetryEventType.alarmOutcome);
    expect(e.props['mode'], 'distance');
    expect(e.props['reach'], false);
  });

  test('metro-stops fire => alarmOutcome{mode:stops}', () async {
    await fire('Metro Final Destination (2 stops prior)');
    final e = sink.events
        .firstWhere((e) => e.type == TelemetryEventType.alarmOutcome);
    expect(e.props['mode'], 'stops');
  });
}
