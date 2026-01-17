// EKF test helpers (placeholder scaffolding)
// NOTE: Fill with deterministic generators before writing tests.

import 'dart:math';

class ImuSample {
  final double ax;
  final double ay;
  final double az;
  final double gx;
  final double gy;
  final double gz;
  final Duration timestamp;

  const ImuSample({
    required this.ax,
    required this.ay,
    required this.az,
    required this.gx,
    required this.gy,
    required this.gz,
    required this.timestamp,
  });
}

class ImuSequence {
  final List<ImuSample> samples;
  const ImuSequence(this.samples);
}

ImuSequence generateStaticImu({
  int hz = 100,
  Duration duration = const Duration(seconds: 5),
  double g = 9.81,
}) {
  final count = hz * duration.inSeconds;
  final samples = List.generate(count, (i) {
    return ImuSample(
      ax: 0,
      ay: 0,
      az: g,
      gx: 0,
      gy: 0,
      gz: 0,
      timestamp: Duration(milliseconds: (1000 / hz * i).round()),
    );
  });
  return ImuSequence(samples);
}

List<double> linspace(double start, double end, int n) {
  if (n <= 1) return [start];
  final step = (end - start) / (n - 1);
  return List.generate(n, (i) => start + step * i);
}

class RouteFixture {
  final List<double> lats;
  final List<double> lngs;
  const RouteFixture(this.lats, this.lngs);
}

RouteFixture straightLineRoute({
  double lat0 = 12.0,
  double lng0 = 77.0,
  double lat1 = 12.001,
  double lng1 = 77.001,
  int points = 10,
}) {
  return RouteFixture(
    linspace(lat0, lat1, points),
    linspace(lng0, lng1, points),
  );
}

RouteFixture lShapedRoute({
  double lat0 = 12.0,
  double lng0 = 77.0,
  double lat1 = 12.001,
  double lng1 = 77.0,
  double lat2 = 12.001,
  double lng2 = 77.001,
  int points = 6,
}) {
  final first = linspace(lat0, lat1, points ~/ 2);
  final second = linspace(lng0, lng2, points ~/ 2);
  return RouteFixture(
    [...first, ...List.filled(points ~/ 2, lat2)],
    [...List.filled(points ~/ 2, lng1), ...second],
  );
}

Random seededRandom(int seed) => Random(seed);
