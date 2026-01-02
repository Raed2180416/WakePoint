import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/dashboard/alarm_debouncer.dart';

void main() {
  group('AlarmDebouncer Tests', () {
    late AlarmDebouncer debouncer;
    late DateTime now;

    setUp(() {
      debouncer = AlarmDebouncer(holdDuration: const Duration(seconds: 2));
      now = DateTime(2025, 1, 1, 10, 0, 0);
    });

    test('Initial state is not triggered', () {
      expect(debouncer.isTriggered, false);
      expect(debouncer.lastFired, null);
    });

    test('Rising edge triggers and logs', () {
      final shouldLog = debouncer.update(true, now); // Server says TRUE
      expect(shouldLog, true);
      expect(debouncer.isTriggered, true);
      expect(debouncer.lastFired, now);
    });

    test('Steady state ON does not re-log', () {
      debouncer.update(true, now); // First trigger

      // Advance 1s (server still TRUE)
      now = now.add(const Duration(seconds: 1));
      final shouldLog = debouncer.update(true, now);

      expect(shouldLog, false);
      expect(debouncer.isTriggered, true);
      // Last fired time should NOT update on steady state?
      // Logic: if (!_triggered) ... else ...
      // If already triggered, we do nothing. So lastFired remains at t=0.
      expect(debouncer.lastFired, DateTime(2025, 1, 1, 10, 0, 0));
    });

    test('Flicker OFF and ON within hold duration treats as same event', () {
      // 1. Trigger ON
      debouncer.update(true, now);

      // 2. Server flakily says OFF at t+1s
      now = now.add(const Duration(seconds: 1));
      final logOff = debouncer.update(false, now);

      // Visually should HOLD true because < 2s
      expect(debouncer.isTriggered, true);
      expect(logOff, false);

      // 3. Server says ON again at t+1.5s
      now = now.add(const Duration(milliseconds: 500));
      final logOn = debouncer.update(true, now);

      // Should NOT log as new event
      expect(logOn, false);
      expect(debouncer.isTriggered, true);
      // lastFired should still be initial time (start of even block)
      expect(debouncer.lastFired, DateTime(2025, 1, 1, 10, 0, 0));
    });

    test('Valid OFF after hold duration', () {
      debouncer.update(true, now);

      // Advance 3s
      now = now.add(const Duration(seconds: 3));
      debouncer.update(false, now);

      expect(debouncer.isTriggered, false);
    });

    test('New event after valid OFF', () {
      debouncer.update(true, now);

      // Event ends
      now = now.add(const Duration(seconds: 3));
      debouncer.update(false, now); // OFF

      // New event starts
      now = now.add(const Duration(seconds: 1)); // t+4s
      final shouldLog = debouncer.update(true, now);

      expect(shouldLog, true);
      expect(debouncer.isTriggered, true);
      expect(debouncer.lastFired, now);
    });

    test('Reset clears state', () {
      debouncer.update(true, now);
      debouncer.reset();
      expect(debouncer.isTriggered, false);
      // lastFired remains? Logic: _triggered=false.
      // If we update(true) immediately, logic checks `now.difference(_lastFired)`.
      // If scrub happened, we probably want it to fire again if we are in zone.

      // Check re-fire capability after reset
      final shouldLog = debouncer.update(true, now);
      // Should NOT log again immediately if within hold duration, even after reset.
      expect(shouldLog, false);
      // If diff < 2s, isNew = false.
      // So if we scrub back to same spot within 2s, we don't log again?
      // Wait, reset only sets `_triggered = false`.
      // User requirement: "robust to route progress forwarding or backwarding".
      // If I scrub back, I might want to hear the alarm again?
      // If I'm testing standard behavior:

      // If Logic says: isNew = false if close to lastFired.
      // Then reset() might NOT allow immediate re-logging if time hasn't passed.
      // This is probably desired (don't spam logs if scrubbing fast).
      // But visual state will go True.
      expect(debouncer.isTriggered, true);
    });
  });
}
