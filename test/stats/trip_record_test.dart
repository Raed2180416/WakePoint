import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/privacy/pii_guard.dart';
import 'package:geowake2/services/stats/trip_record.dart';

void main() {
  group('TripRecord', () {
    test('build derives hour/weekday and defaults wokenOnTime from outcome', () {
      final at = DateTime(2026, 7, 19, 14, 30); // a Sunday, 2:30pm
      final r = TripRecord.build(
        mode: 'stops',
        outcome: 'onTime',
        completedAtMs: at.millisecondsSinceEpoch,
      );
      expect(r.hourOfDay, 14);
      expect(r.weekday, DateTime.sunday);
      expect(r.wokenOnTime, isTrue);
    });

    test('late / missed outcomes default wokenOnTime false', () {
      final late = TripRecord.build(mode: 'time', outcome: 'late');
      final missed = TripRecord.build(mode: 'time', outcome: 'missed');
      expect(late.wokenOnTime, isFalse);
      expect(missed.wokenOnTime, isFalse);
    });

    test('validate rejects a coordinate-looking station', () {
      final r = TripRecord.build(
        mode: 'stops',
        outcome: 'onTime',
        destStation: '12.9716, 77.5946',
      );
      expect(() => r.validate(), throwsA(isA<PiiViolation>()));
    });

    test('validate rejects an email-looking city', () {
      final r = TripRecord.build(
        mode: 'stops',
        outcome: 'onTime',
        city: 'user@example.com',
      );
      expect(() => r.validate(), throwsA(isA<PiiViolation>()));
    });

    test('validate accepts clean coarse names', () {
      final r = TripRecord.build(
        mode: 'stops',
        outcome: 'onTime',
        destStation: 'Indiranagar',
        line: 'Purple Line',
        city: 'Bengaluru',
      );
      expect(() => r.validate(), returnsNormally);
    });

    test('json round-trips', () {
      final r = TripRecord.build(
        mode: 'distance',
        outcome: 'onTime',
        destStation: 'MG Road',
        line: 'Purple Line',
        city: 'Bengaluru',
        completedAtMs: 1700000000000,
      );
      final back = TripRecord.fromJson(r.toJson());
      expect(back, isNotNull);
      expect(back!.destStation, 'MG Road');
      expect(back.line, 'Purple Line');
      expect(back.mode, 'distance');
      expect(back.wokenOnTime, isTrue);
      expect(back.completedAtMs, 1700000000000);
    });

    test('fromJson returns null on a malformed row', () {
      expect(TripRecord.fromJson(<String, dynamic>{'garbage': true}), isNull);
    });
  });
}
