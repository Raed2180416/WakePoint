// test/services/projection_correction_test.dart
//
// Regression tests for BACKLOG #27: SNAPPING PROJECTION CORRECTION.
//
// `projectPointOnSegment` (shared by StopMatcher and the polyline_decoder
// snappers) used to project in RAW degree space, treating one degree of
// longitude as equal to one degree of latitude. Away from the equator that is
// false — a degree of longitude spans fewer meters — so projections onto any
// segment with an east-west component were skewed, moving the snapped stop and
// its meters-along-route. The fix applies a cos(midpoint-latitude) correction
// to the longitude delta (matching SnapToRouteEngine's equirectangular math)
// and factors it into ONE shared helper so the two snappers cannot diverge.
//
// These tests are pure (no plugins) and deterministic.

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/polyline_decoder.dart';
import 'package:geowake2/services/stop_matcher.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

double _toRad(double deg) => deg * pi / 180.0;

/// Independent cos(lat)-corrected analytic projection, derived by mapping the
/// three points into a local equirectangular meter frame (x = lng*cos(lat0),
/// y = lat), projecting with a plain vector dot product, then mapping back.
/// This is the physically-correct answer the helper must reproduce.
({double t, LatLng snapped}) _expectedCosCorrected(LatLng a, LatLng b, LatLng p) {
  final c = cos(_toRad((a.latitude + b.latitude) * 0.5));
  final ax = a.longitude * c, ay = a.latitude;
  final bx = b.longitude * c, by = b.latitude;
  final px = p.longitude * c, py = p.latitude;
  final vx = bx - ax, vy = by - ay;
  final wx = px - ax, wy = py - ay;
  final vv = vx * vx + vy * vy;
  var t = vv > 0 ? (wx * vx + wy * vy) / vv : 0.0;
  t = t.clamp(0.0, 1.0);
  final sx = ax + t * vx, sy = ay + t * vy;
  return (t: t, snapped: LatLng(sy, sx / c));
}

/// The OLD raw-degree-space projection (the buggy behaviour), used to prove the
/// correction materially changes the result.
({double t, LatLng snapped}) _oldRaw(LatLng a, LatLng b, LatLng p) {
  final dx = b.longitude - a.longitude;
  final dy = b.latitude - a.latitude;
  final lenSq = dx * dx + dy * dy;
  var t =
      ((p.longitude - a.longitude) * dx + (p.latitude - a.latitude) * dy) /
      lenSq;
  t = t.clamp(0.0, 1.0);
  return (t: t, snapped: LatLng(a.latitude + t * dy, a.longitude + t * dx));
}

void main() {
  group('projectPointOnSegment cos(lat) correction (BACKLOG #27)', () {
    // A segment with an east-west component at a high latitude, where the
    // longitude compression is strong (cos 60 deg ~= 0.5). Point p sits due
    // north of the segment start.
    final a = const LatLng(60.000, 10.000);
    final b = const LatLng(60.001, 10.001);
    final p = const LatLng(60.001, 10.000);

    test('matches the cos(lat)-corrected analytic answer', () {
      final got = projectPointOnSegment(a, b, p);
      final want = _expectedCosCorrected(a, b, p);

      expect(got.t, closeTo(want.t, 1e-9));
      expect(got.point.latitude, closeTo(want.snapped.latitude, 1e-9));
      expect(got.point.longitude, closeTo(want.snapped.longitude, 1e-9));

      // Anchor to the hand-computed value so the test is not merely circular:
      // t is ~0.80, NOT the raw-math 0.50.
      expect(got.t, closeTo(0.8000048, 1e-6));
    });

    test('the OLD raw math would have been materially wrong', () {
      final got = projectPointOnSegment(a, b, p);
      final raw = _oldRaw(a, b, p);

      // Raw math lands at the segment midpoint (t = 0.5); the correction pushes
      // the true foot to t ~= 0.80 — a 0.30 shift along the segment.
      expect(raw.t, closeTo(0.5, 1e-9));
      expect((got.t - raw.t).abs(), greaterThan(0.05));

      // The two snapped coordinates are tens of meters apart — enough to move
      // an alarm's arrival estimate.
      final drift = haversineDistance(got.point, raw.snapped);
      expect(drift, greaterThan(10.0));
    });

    test('behaviour is identical to raw math for purely north-south segments',
        () {
      // Pure N-S segment: no longitude delta, so cos(lat) must cancel out.
      final ns_a = const LatLng(60.000, 10.000);
      final ns_b = const LatLng(60.002, 10.000);
      final ns_p = const LatLng(60.0011, 10.020); // off to the east

      final got = projectPointOnSegment(ns_a, ns_b, ns_p);
      final raw = _oldRaw(ns_a, ns_b, ns_p);

      expect(got.t, closeTo(raw.t, 1e-12));
      expect(got.point.latitude, closeTo(raw.snapped.latitude, 1e-12));
      // Snapped longitude stays pinned to the meridian either way.
      expect(got.point.longitude, closeTo(ns_a.longitude, 1e-12));
      expect(raw.snapped.longitude, closeTo(ns_a.longitude, 1e-12));
    });

    test('clamps the parameter to the segment endpoints', () {
      // p projects beyond b.
      final beyond = const LatLng(60.003, 10.003);
      final got = projectPointOnSegment(a, b, beyond);
      expect(got.t, 1.0);
      expect(got.point.latitude, closeTo(b.latitude, 1e-12));
      expect(got.point.longitude, closeTo(b.longitude, 1e-12));
    });
  });

  group('both snappers share the corrected helper (cannot diverge)', () {
    // Single-segment polyline == one call into the shared projection helper.
    final segStart = const LatLng(60.000, 10.000);
    final segEnd = const LatLng(60.001, 10.001);
    final polyline = [segStart, segEnd];
    final stopLoc = const LatLng(60.001, 10.000);

    test('polyline_decoder.snapPointToPolyline uses the corrected geometry', () {
      final snap = snapPointToPolyline(polyline, stopLoc);
      expect(snap, isNotNull);
      final want = _expectedCosCorrected(segStart, segEnd, stopLoc);
      expect(snap!.snapped.latitude, closeTo(want.snapped.latitude, 1e-9));
      expect(snap.snapped.longitude, closeTo(want.snapped.longitude, 1e-9));
    });

    test('StopMatcher snaps stops with the same corrected geometry', () {
      final matched = StopMatcher.matchStopsToPolyline(
        polyline: polyline,
        stops: const [
          Stop(id: 's1', name: 'Test', location: LatLng(60.001, 10.000)),
        ],
        radiusMeters: 1000.0,
      );
      expect(matched, hasLength(1));
      final want = _expectedCosCorrected(segStart, segEnd, stopLoc);
      expect(matched.first.snapped.latitude, closeTo(want.snapped.latitude, 1e-9));
      expect(matched.first.snapped.longitude, closeTo(want.snapped.longitude, 1e-9));
    });
  });
}
