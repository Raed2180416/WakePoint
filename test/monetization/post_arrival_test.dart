import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/monetization/post_arrival_service.dart';

void main() {
  group('PostArrivalService.build', () {
    test('title includes the station name', () {
      final card = PostArrivalService.build(stationName: 'Indiranagar');
      expect(card.title, contains('Indiranagar'));
      expect(card.title, "You've arrived at Indiranagar");
      expect(card.stationName, 'Indiranagar');
    });

    test('trims whitespace off the station name', () {
      final card = PostArrivalService.build(stationName: '  MG Road  ');
      expect(card.stationName, 'MG Road');
      expect(card.title, "You've arrived at MG Road");
    });

    test('falls back to a generic title when station is empty', () {
      final card = PostArrivalService.build(stationName: '   ');
      expect(card.title, "You've arrived");
      expect(card.stationName, '');
    });

    test('ride-hailing action is present, primary, and first', () {
      final card = PostArrivalService.build(stationName: 'Indiranagar');

      // Present.
      final rides = card.actions
          .where((a) => a.kind == PostArrivalActionKind.rideHailing)
          .toList();
      expect(rides.length, 1, reason: 'exactly one ride-hailing CTA');

      // Primary.
      final primary = card.primaryAction;
      expect(primary, isNotNull);
      expect(primary!.kind, PostArrivalActionKind.rideHailing);
      expect(primary.isPrimary, isTrue);
      expect(primary.label, 'Book a ride from the station');

      // First — the highest-value action leads the card.
      expect(card.actions.first.kind, PostArrivalActionKind.rideHailing);

      // At most one primary action.
      expect(card.actions.where((a) => a.isPrimary).length, 1);
    });

    test('always appends a dismiss action, last and non-primary', () {
      final card = PostArrivalService.build(stationName: 'Indiranagar');
      final last = card.actions.last;
      expect(last.kind, PostArrivalActionKind.dismiss);
      expect(last.isPrimary, isFalse);
    });

    test('maps injected nearby food/directions options into actions', () {
      final card = PostArrivalService.build(
        stationName: 'Indiranagar',
        city: 'Bengaluru',
        nearby: const [
          LastMileOption(label: 'Coffee at the exit', kind: 'food'),
          LastMileOption(label: 'Walk to 100ft Road', kind: 'directions'),
        ],
      );

      final kinds = card.actions.map((a) => a.kind).toList();
      // rideHailing (primary) → food → directions → dismiss.
      expect(kinds, [
        PostArrivalActionKind.rideHailing,
        PostArrivalActionKind.food,
        PostArrivalActionKind.directions,
        PostArrivalActionKind.dismiss,
      ]);
      expect(card.city, 'Bengaluru');
    });

    test('dedupes an injected ride-hailing option against the primary CTA', () {
      final card = PostArrivalService.build(
        stationName: 'Indiranagar',
        nearby: const [
          LastMileOption(label: 'Ola from here', kind: 'rideHailing'),
          LastMileOption(label: 'Snacks', kind: 'food'),
        ],
      );

      expect(
        card.actions
            .where((a) => a.kind == PostArrivalActionKind.rideHailing)
            .length,
        1,
        reason: 'the injected ride-hailing option must not add a second CTA',
      );
      // The single ride-hailing action is still the synthesised primary.
      expect(card.primaryAction!.label, 'Book a ride from the station');
    });

    test('ignores unknown injected kinds and empty labels', () {
      final card = PostArrivalService.build(
        stationName: 'Indiranagar',
        nearby: const [
          LastMileOption(label: 'Casino', kind: 'gambling'),
          LastMileOption(label: '   ', kind: 'food'),
          LastMileOption(label: 'Cannot dismiss via nearby', kind: 'dismiss'),
        ],
      );

      // Only the primary ride-hailing + the always-on dismiss remain.
      final kinds = card.actions.map((a) => a.kind).toList();
      expect(kinds, [
        PostArrivalActionKind.rideHailing,
        PostArrivalActionKind.dismiss,
      ]);
    });
  });

  group('PostArrivalService.shouldShow (alarm gate)', () {
    test('is false until the wake alarm is dismissed', () {
      expect(PostArrivalService.shouldShow(alarmDismissed: false), isFalse);
    });

    test('is true once the wake alarm is dismissed', () {
      expect(PostArrivalService.shouldShow(alarmDismissed: true), isTrue);
    });
  });

  group('privacy invariant (no coordinates, no PII)', () {
    test('a normally built card validates clean', () {
      final card = PostArrivalService.build(
        stationName: 'Indiranagar',
        city: 'Bengaluru',
        nearby: const [
          LastMileOption(label: 'Coffee at the exit', kind: 'food'),
          LastMileOption(label: 'Walk to 100ft Road', kind: 'directions'),
        ],
      );
      expect(card.validate, returnsNormally);

      // Defensive structural check: no field carries a coordinate pair.
      final coordPair = RegExp(r'-?\d{1,3}\.\d{3,}\s*[,;]\s*-?\d{1,3}\.\d{3,}');
      expect(coordPair.hasMatch(card.title), isFalse);
      expect(coordPair.hasMatch(card.stationName), isFalse);
      for (final a in card.actions) {
        expect(coordPair.hasMatch(a.label), isFalse);
      }
    });

    test('build() rejects a coordinate-pair station name', () {
      expect(
        () => PostArrivalService.build(stationName: '12.9716, 77.5946'),
        throwsA(isA<PostArrivalPrivacyError>()),
      );
    });

    test('build() rejects a high-precision decimal-degree station name', () {
      expect(
        () => PostArrivalService.build(stationName: 'Zone 12.97159'),
        throwsA(isA<PostArrivalPrivacyError>()),
      );
    });

    test('validate() throws on a coordinate-looking station name', () {
      const card = PostArrivalCard(
        title: 'You have arrived',
        stationName: '12.9716,77.5946',
        actions: [
          PostArrivalAction(
            label: 'Book a ride from the station',
            kind: PostArrivalActionKind.rideHailing,
            isPrimary: true,
          ),
        ],
      );
      expect(card.validate, throwsA(isA<PostArrivalPrivacyError>()));
    });

    test('validate() throws on a coordinate leaked into an action label', () {
      const card = PostArrivalCard(
        title: "You've arrived at Indiranagar",
        stationName: 'Indiranagar',
        actions: [
          PostArrivalAction(
            label: 'Ride from 12.9716, 77.5946',
            kind: PostArrivalActionKind.rideHailing,
            isPrimary: true,
          ),
        ],
      );
      expect(card.validate, throwsA(isA<PostArrivalPrivacyError>()));
    });

    test('validate() throws on a leaked lat/lng field name', () {
      const card = PostArrivalCard(
        title: "You've arrived",
        stationName: 'Indiranagar',
        actions: [
          PostArrivalAction(
            label: 'lat=12.9 lng=77.5',
            kind: PostArrivalActionKind.directions,
          ),
        ],
      );
      expect(card.validate, throwsA(isA<PostArrivalPrivacyError>()));
    });

    test('validate() throws on an email address (PII)', () {
      const card = PostArrivalCard(
        title: "You've arrived",
        stationName: 'Indiranagar',
        actions: [
          PostArrivalAction(
            label: 'Contact rider@example.com',
            kind: PostArrivalActionKind.directions,
          ),
        ],
      );
      expect(card.validate, throwsA(isA<PostArrivalPrivacyError>()));
    });

    test('validate() throws on a phone/id-looking digit run (PII)', () {
      const card = PostArrivalCard(
        title: "You've arrived",
        stationName: 'Indiranagar',
        actions: [
          PostArrivalAction(
            label: 'Call 9876543210',
            kind: PostArrivalActionKind.rideHailing,
            isPrimary: true,
          ),
        ],
      );
      expect(card.validate, throwsA(isA<PostArrivalPrivacyError>()));
    });

    test('validate() throws on an unrecognised action kind', () {
      const card = PostArrivalCard(
        title: "You've arrived at Indiranagar",
        stationName: 'Indiranagar',
        actions: [
          PostArrivalAction(label: 'Do a thing', kind: 'mystery'),
        ],
      );
      expect(card.validate, throwsA(isA<ArgumentError>()));
    });

    test('the privacy error names the field but never echoes the value', () {
      final err = PostArrivalPrivacyError('stationName', 'looks like a pair');
      final msg = err.toString();
      expect(msg, contains('stationName'));
      // Must not leak the offending value through the error message.
      expect(msg.contains('12.9716'), isFalse);
    });

    test('telemetry projection carries only name/zone + kind-level actions', () {
      final card = PostArrivalService.build(
        stationName: 'Indiranagar',
        city: 'Bengaluru',
        nearby: const [
          LastMileOption(label: 'Coffee at the exit', kind: 'food'),
        ],
      );
      final map = card.toMap();
      final actions = map['actions'] as List;
      // Action projections expose kind + isPrimary only — no labels leak.
      for (final a in actions) {
        final m = a as Map<String, dynamic>;
        expect(m.keys.toSet(), {'kind', 'isPrimary'});
      }
      expect(map['stationName'], 'Indiranagar');
      expect(map['city'], 'Bengaluru');
    });
  });
}
