// Station association (Stage G).

class StationAssociationConfig {
  const StationAssociationConfig({
    this.marginMeters = 50,
    this.dwellSeconds = 20,
  });

  final double marginMeters;
  final int dwellSeconds;
}

class StationAssociationResult {
  final int stationIndex;
  final double stationMeters;

  const StationAssociationResult({
    required this.stationIndex,
    required this.stationMeters,
  });
}

class StationAssociation {
  StationAssociation({StationAssociationConfig? config})
      : _config = config ?? const StationAssociationConfig();

  final StationAssociationConfig _config;

  StationAssociationResult? selectCandidate({
    required List<double> stationMeters,
    required double sEst,
    required double sigmaS,
    required bool isMetroLeg,
    required bool zuptConfirmed,
    required Duration zuptDwell,
  }) {
    if (!isMetroLeg) return null;
    if (!zuptConfirmed) return null;
    if (zuptDwell.inSeconds < _config.dwellSeconds) return null;
    if (stationMeters.isEmpty) return null;

    final window = 3 * sigmaS + _config.marginMeters;
    final candidates = <int>[];
    for (var i = 0; i < stationMeters.length; i++) {
      final d = (stationMeters[i] - sEst).abs();
      if (d <= window) {
        candidates.add(i);
      }
    }

    if (candidates.length != 1) return null;

    final idx = candidates.single;
    return StationAssociationResult(
      stationIndex: idx,
      stationMeters: stationMeters[idx],
    );
  }
}
