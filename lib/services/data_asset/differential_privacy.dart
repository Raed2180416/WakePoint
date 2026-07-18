// lib/services/data_asset/differential_privacy.dart
//
// GeoWake — differential privacy (DATA_SURFACE_SPEC §2.7).
//
// Pure Laplace mechanism + the disclosure that pins the mechanism for the buyer
// datasheet / DPIA. Seedable RNG so tests are deterministic.
//
// Red-team fix R4: noise is applied in the CENTRAL model, at merge. ε is NOT
// comparable across DP models, so [dpDisclosure] states model + ε + sensitivity
// and the config tripwire test asserts it matches the stated constants. Double
// -noising is forbidden — the on-device candidate is noised exactly once for the
// methodology view; the authoritative release noise is added once at merge.

import 'dart:math' as math;

import 'data_asset_config.dart';

/// Which DP model the stated ε refers to. Central = trusted aggregator adds
/// noise once to the merged counts (the model GeoWake uses).
enum DpModel { local, central }

/// The stated DP parameter triple (model + per-cell ε + per-user daily ε budget
/// + per-cell sensitivity bound).
class DpParams {
  final DpModel model;
  final double epsilonPerCell;
  final double perUserDailyEpsilon;
  final int sensitivity;

  const DpParams({
    this.model = DpModel.central,
    this.epsilonPerCell = kEpsilonPerCell,
    this.perUserDailyEpsilon = kPerUserDailyEpsilonCap,
    this.sensitivity = kPerUserMaxCountPerCellPerDay,
  });

  static const DpParams stated = DpParams();
}

class LaplaceMechanism {
  /// Adds Laplace(scale = sensitivity/epsilon) noise to [trueCount], rounds, and
  /// clamps to a non-negative integer (a released count can never be negative).
  ///
  /// [rng] is injectable for deterministic tests. [epsilon] must be > 0 and
  /// [sensitivity] >= 1.
  int noisyCount(
    int trueCount, {
    required double epsilon,
    int sensitivity = kPerUserMaxCountPerCellPerDay,
    math.Random? rng,
  }) {
    assert(epsilon > 0, 'epsilon must be positive');
    assert(sensitivity >= 1, 'sensitivity must be >= 1');
    final scale = sensitivity / epsilon;
    final r = rng ?? math.Random();
    final noise = _sampleLaplace(scale, r);
    final noisy = (trueCount + noise).round();
    return noisy < 0 ? 0 : noisy;
  }

  /// Inverse-CDF Laplace sampling with mean 0 and the given [scale] (= b).
  /// Draw u ∈ (-0.5, 0.5]; noise = -b·sign(u)·ln(1 - 2|u|).
  double _sampleLaplace(double scale, math.Random rng) {
    // nextDouble() ∈ [0,1); map to (-0.5, 0.5].
    final u = 0.5 - rng.nextDouble();
    final sign = u < 0 ? -1.0 : 1.0;
    // Guard the log domain: 1 - 2|u| ∈ (0, 1].
    final mag = 1 - 2 * u.abs();
    final safeMag = mag <= 0 ? 1e-12 : mag;
    return -scale * sign * math.log(safeMag);
  }

  /// The buyer-facing / DPIA disclosure. Pins model + ε + sensitivity so a buyer
  /// (and the config tripwire test) can verify exactly what noise was applied.
  static Map<String, Object?> dpDisclosure({DpParams params = DpParams.stated}) {
    return {
      'mechanism': 'laplace',
      'model': params.model.name, // 'central'
      'epsilonPerCell': params.epsilonPerCell, // 0.44
      'perUserDailyEpsilon': params.perUserDailyEpsilon, // 1.76
      'sensitivity': params.sensitivity, // 1 (per cell/day indicator)
      'perUserMaxCellsPerDay': kPerUserMaxCellsPerDay, // 4
      'kAnonymityThreshold': kOdKAnonymityThreshold, // 100
      'noiseAppliedAt': 'merge', // central model, once
    };
  }
}
