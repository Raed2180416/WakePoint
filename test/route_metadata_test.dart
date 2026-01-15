import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/route_metadata.dart';
import 'package:geowake2/services/reroute_constraints.dart';
import 'package:flutter/material.dart';

void main() {
  group('RouteMetadata', () {
    test('constructs with required parameters', () {
      final metadata = RouteMetadata(
        routeKey: 'route_123',
        routeType: 'original',
      );

      expect(metadata.routeKey, 'route_123');
      expect(metadata.routeType, 'original');
      expect(metadata.lineColors, isEmpty);
      expect(metadata.firedEventIndices, isEmpty);
      expect(metadata.firedLegIds, isEmpty);
      expect(metadata.constraints, isNull);
    });

    test('constructs with all optional parameters', () {
      final constraints = RerouteConstraints(
        alarmMode: 'stops',
        alarmValue: 3.0,
        transitMode: true,
      );

      final metadata = RouteMetadata(
        routeKey: 'route_456',
        routeType: 'reroute',
        lineColors: {'segment_0': Colors.blue, 'segment_1': Colors.red},
        firedEventIndices: {2, 5, 7},
        firedLegIds: {'leg_a', 'leg_b'},
        constraints: constraints,
        initialStopsRemaining: 5,
      );

      expect(metadata.lineColors.length, 2);
      expect(metadata.lineColors['segment_0'], Colors.blue);
      expect(metadata.firedEventIndices.contains(5), isTrue);
      expect(metadata.firedLegIds.contains('leg_a'), isTrue);
      expect(metadata.constraints?.alarmMode, 'stops');
      expect(metadata.initialStopsRemaining, 5);
    });

    group('factory constructors', () {
      test('original creates correct type', () {
        final metadata = RouteMetadata.original(
          routeKey: 'orig_1',
          stopsRemaining: 10,
        );

        expect(metadata.routeType, 'original');
        expect(metadata.routeKey, 'orig_1');
        expect(metadata.initialStopsRemaining, 10);
      });

      test('reroute creates correct type', () {
        final constraints = RerouteConstraints(
          alarmMode: 'time',
          alarmValue: 5.0,
          transitMode: false,
        );

        final metadata = RouteMetadata.reroute(
          routeKey: 'reroute_1',
          constraints: constraints,
          durationRemaining: const Duration(minutes: 30),
        );

        expect(metadata.routeType, 'reroute');
        expect(metadata.constraints, isNotNull);
        expect(metadata.initialDurationRemaining?.inMinutes, 30);
      });

      test('alternative creates correct type', () {
        final metadata = RouteMetadata.alternative(
          routeKey: 'alt_1',
          distanceRemainingKm: 5.5,
        );

        expect(metadata.routeType, 'alternative');
        expect(metadata.initialDistanceRemainingKm, 5.5);
      });
    });

    group('event tracking', () {
      test('markEventFired adds index to firedEventIndices', () {
        final metadata = RouteMetadata(
          routeKey: 'route_1',
          routeType: 'original',
        );

        metadata.markEventFired(5);

        expect(metadata.firedEventIndices.contains(5), isTrue);
      });

      test('hasEventFired returns correct value', () {
        final metadata = RouteMetadata(
          routeKey: 'route_1',
          routeType: 'original',
          firedEventIndices: {1, 2, 3},
        );

        expect(metadata.hasEventFired(2), isTrue);
        expect(metadata.hasEventFired(5), isFalse);
      });

      test('markLegFired adds legId to firedLegIds', () {
        final metadata = RouteMetadata(
          routeKey: 'route_1',
          routeType: 'original',
        );

        metadata.markLegFired('leg_xyz');

        expect(metadata.firedLegIds.contains('leg_xyz'), isTrue);
      });

      test('hasLegFired returns correct value', () {
        final metadata = RouteMetadata(
          routeKey: 'route_1',
          routeType: 'original',
          firedLegIds: {'leg_a', 'leg_b'},
        );

        expect(metadata.hasLegFired('leg_a'), isTrue);
        expect(metadata.hasLegFired('leg_z'), isFalse);
      });
    });

    group('line colors', () {
      test('setLineColor adds color for segment', () {
        final metadata = RouteMetadata(
          routeKey: 'route_1',
          routeType: 'original',
        );

        metadata.setLineColor('segment_0', Colors.purple);

        expect(metadata.lineColors['segment_0'], Colors.purple);
      });

      test('setLineColor overwrites existing color', () {
        final metadata = RouteMetadata(
          routeKey: 'route_1',
          routeType: 'original',
          lineColors: {'segment_0': Colors.blue},
        );

        metadata.setLineColor('segment_0', Colors.orange);

        expect(metadata.lineColors['segment_0'], Colors.orange);
      });
    });

    group('alarm state migration', () {
      test('migrateAlarmStateFrom resets destination alarm', () {
        final source = RouteMetadata(
          routeKey: 'old_route',
          routeType: 'original',
          destinationAlarmFired: true,
        );

        final target = RouteMetadata(
          routeKey: 'new_route',
          routeType: 'reroute',
        );

        target.migrateAlarmStateFrom(source);

        expect(target.destinationAlarmFired, isFalse);
      });
    });
  });
}
