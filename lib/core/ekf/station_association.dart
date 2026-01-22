// Station association (Stage G).

/// Diagnostic info about why station association failed.
class StationAssociationDiagnostics {
  final bool isMetroLeg;
  final bool zuptConfirmed;
  final int zuptDwellMs;
  final int requiredDwellMs;
  final int numStations;
  final double sEst;
  final double sigmaS;
  final double windowMeters;
  final int numCandidates;
  final List<int> candidateIndices;
  final List<double> candidateDistances;
  final int? selectedIndex;
  final String? selectionMode;
  final String? rejectReason;

  const StationAssociationDiagnostics({
    required this.isMetroLeg,
    required this.zuptConfirmed,
    required this.zuptDwellMs,
    required this.requiredDwellMs,
    required this.numStations,
    required this.sEst,
    required this.sigmaS,
    required this.windowMeters,
    required this.numCandidates,
    required this.candidateIndices,
    required this.candidateDistances,
    this.selectedIndex,
    this.selectionMode,
    this.rejectReason,
  });

  Map<String, dynamic> toJson() => {
    'isMetroLeg': isMetroLeg,
    'zuptConfirmed': zuptConfirmed,
    'zuptDwellMs': zuptDwellMs,
    'requiredDwellMs': requiredDwellMs,
    'numStations': numStations,
    'sEst': sEst.toStringAsFixed(0),
    'sigmaS': sigmaS.toStringAsFixed(1),
    'windowMeters': windowMeters.toStringAsFixed(0),
    'numCandidates': numCandidates,
    'candidateIndices': candidateIndices,
    'candidateDistances': candidateDistances.map((d) => d.toStringAsFixed(0)).toList(),
    if (selectedIndex != null) 'selectedIndex': selectedIndex,
    if (selectionMode != null) 'selectionMode': selectionMode,
    if (rejectReason != null) 'rejectReason': rejectReason,
  };
}

class StationAssociationConfig {
  const StationAssociationConfig({
    this.baseMarginMeters = 50,  // Base margin for high-confidence estimates
    this.maxMarginMeters = 150,  // Maximum margin cap
    this.marginPerSigma = 0.5,   // Additional margin per sigma of uncertainty
    this.dwellSeconds = 3,       // Reduced from 5: faster snap for testing (ZUPT has its own 3s dwell)
  });

  final double baseMarginMeters;
  final double maxMarginMeters;
  final double marginPerSigma; // Adaptive margin based on uncertainty
  final int dwellSeconds;
  
  /// Calculate adaptive margin: higher uncertainty → smaller margin.
  /// This prevents window overlap when sigmaS is large.
  /// 
  /// Logic: margin = baseMargin + marginPerSigma * sigmaS, capped at maxMargin
  /// When sigmaS is small (good estimate): larger window for tolerance
  /// When sigmaS is large (bad estimate): tighter window to avoid multi-candidates
  double marginForSigma(double sigmaS) {
    // Adaptive margin that shrinks as uncertainty grows
    // At sigmaS=10: margin = 50 + 0.5*10 = 55m → window = 3*10 + 55 = 85m (tight)
    // At sigmaS=50: margin = 50 + 0.5*50 = 75m → window = 3*50 + 75 = 225m
    // At sigmaS=100: margin = 50 + 0.5*100 = 100m → window = 3*100 + 100 = 400m
    // Cap prevents excessive window when sigmaS is huge
    final adaptiveMargin = baseMarginMeters + marginPerSigma * sigmaS;
    return adaptiveMargin.clamp(baseMarginMeters, maxMarginMeters);
  }
}

class StationAssociationResult {
  final int stationIndex;
  final double stationMeters;
  final StationAssociationDiagnostics? diagnostics;

  const StationAssociationResult({
    required this.stationIndex,
    required this.stationMeters,
    this.diagnostics,
  });
}

class StationAssociation {
  StationAssociation({StationAssociationConfig? config})
      : _config = config ?? const StationAssociationConfig();

  final StationAssociationConfig _config;
  
  /// Last diagnostics for debugging.
  StationAssociationDiagnostics? lastDiagnostics;

  StationAssociationResult? selectCandidate({
    required List<double> stationMeters,
    required double sEst,
    required double sigmaS,
    required bool isMetroLeg,
    required bool zuptConfirmed,
    required Duration zuptDwell,
    bool isDegraded = false,
  }) {
    // Use adaptive margin based on current uncertainty
    final adaptiveMargin = _config.marginForSigma(sigmaS);
    final window = 3 * sigmaS + adaptiveMargin;
    
    // Find all candidates first (for diagnostics)
    final candidates = <int>[];
    final candidateDistances = <double>[];
    for (var i = 0; i < stationMeters.length; i++) {
      final d = (stationMeters[i] - sEst).abs();
      if (d <= window) {
        candidates.add(i);
        candidateDistances.add(d);
      }
    }
    
    String? rejectReason;
    int? selectedIndex;
    String? selectionMode;
    if (!isMetroLeg) {
      rejectReason = 'NOT_METRO_LEG';
    } else if (!zuptConfirmed) {
      rejectReason = 'ZUPT_NOT_CONFIRMED';
    } else if (zuptDwell.inSeconds < _config.dwellSeconds) {
      rejectReason = 'DWELL_TOO_SHORT (${zuptDwell.inMilliseconds}ms < ${_config.dwellSeconds * 1000}ms)';
    } else if (stationMeters.isEmpty) {
      rejectReason = 'NO_STATIONS';
    } else if (candidates.isEmpty) {
      rejectReason = 'NO_CANDIDATES_IN_WINDOW (window=${window.toStringAsFixed(0)}m)';
    } else if (candidates.length != 1) {
      if (isDegraded && candidates.isNotEmpty) {
        // In degraded mode, prefer the nearest station ahead of sEst.
        int? bestIdx;
        double bestDist = double.infinity;
        for (var i = 0; i < candidates.length; i++) {
          final idx = candidates[i];
          final sStation = stationMeters[idx];
          final d = candidateDistances[i];
          final isAhead = sStation >= sEst;
          if (isAhead && d < bestDist) {
            bestDist = d;
            bestIdx = idx;
          }
        }
        // If none ahead, fall back to nearest overall.
        if (bestIdx == null) {
          for (var i = 0; i < candidates.length; i++) {
            final idx = candidates[i];
            final d = candidateDistances[i];
            if (d < bestDist) {
              bestDist = d;
              bestIdx = idx;
            }
          }
        }
        if (bestIdx != null) {
          selectedIndex = bestIdx;
          selectionMode = 'DEGRADED_NEAREST';
        } else {
          rejectReason = 'MULTIPLE_CANDIDATES (${candidates.length})';
        }
      } else {
        rejectReason = 'MULTIPLE_CANDIDATES (${candidates.length})';
      }
    }
    
    lastDiagnostics = StationAssociationDiagnostics(
      isMetroLeg: isMetroLeg,
      zuptConfirmed: zuptConfirmed,
      zuptDwellMs: zuptDwell.inMilliseconds,
      requiredDwellMs: _config.dwellSeconds * 1000,
      numStations: stationMeters.length,
      sEst: sEst,
      sigmaS: sigmaS,
      windowMeters: window,
      numCandidates: candidates.length,
      candidateIndices: candidates,
      candidateDistances: candidateDistances,
      selectedIndex: selectedIndex,
      selectionMode: selectionMode,
      rejectReason: rejectReason,
    );
    
    // Early exits with diagnostics
    if (!isMetroLeg) return null;
    if (!zuptConfirmed) return null;
    if (zuptDwell.inSeconds < _config.dwellSeconds) return null;
    if (stationMeters.isEmpty) return null;
    if (candidates.length != 1 && selectedIndex == null) return null;

    final idx = selectedIndex ?? candidates.single;
    return StationAssociationResult(
      stationIndex: idx,
      stationMeters: stationMeters[idx],
      diagnostics: lastDiagnostics,
    );
  }
}
