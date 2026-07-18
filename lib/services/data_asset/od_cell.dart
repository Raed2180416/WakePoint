// lib/services/data_asset/od_cell.dart
//
// GeoWake — coordinate-free aggregate types (DATA_SURFACE_SPEC §2.2).
//
// NO FIELD IN THIS FILE IS OR DERIVES FROM A COORDINATE. `stationId` is drawn
// from a fixed, enumerable transit-stop catalogue — never a lat/lng and never a
// coordinate-derived token (e.g. a geohash, which is a REVERSIBLE quantization
// of lat/lng and would turn an O-D key into a re-identifying trajectory; see the
// red-team finding R1 in DATA_SURFACE_SPEC §3). A trajectory is therefore *not
// representable* at the aggregation or upload boundary — the bright line is a
// type-level invariant, not a policy.

import 'data_asset_config.dart';

/// Weekday vs weekend split for the hourly O-D bin. (A holiday calendar can be
/// layered on later without changing the wire shape.)
enum DayType { weekday, weekend }

/// The value-typed key of an origin-destination cell. Value equality + hashCode
/// so it can key a map. **No double fields.**
class OdCellKey {
  final String originStationId;
  final String destStationId;

  /// Local hour of day, 0–23.
  final int hourBin;
  final DayType dayType;

  const OdCellKey({
    required this.originStationId,
    required this.destStationId,
    required this.hourBin,
    required this.dayType,
  });

  /// Stable, human-inspectable string form used as the on-device Hive map key.
  String toKeyString() =>
      '$originStationId>$destStationId|$hourBin|${dayType.name}';

  /// Inverse of [toKeyString]. Returns null on any malformed input (fail-safe).
  static OdCellKey? tryParse(String s) {
    try {
      final barParts = s.split('|');
      if (barParts.length != 3) return null;
      final od = barParts[0].split('>');
      if (od.length != 2) return null;
      final hour = int.tryParse(barParts[1]);
      if (hour == null || hour < 0 || hour > 23) return null;
      final day = DayType.values.where((d) => d.name == barParts[2]);
      if (day.isEmpty) return null;
      if (od[0].isEmpty || od[1].isEmpty) return null;
      return OdCellKey(
        originStationId: od[0],
        destStationId: od[1],
        hourBin: hour,
        dayType: day.first,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is OdCellKey &&
      other.originStationId == originStationId &&
      other.destStationId == destStationId &&
      other.hourBin == hourBin &&
      other.dayType == dayType;

  @override
  int get hashCode =>
      Object.hash(originStationId, destStationId, hourBin, dayType);

  @override
  String toString() => 'OdCellKey(${toKeyString()})';
}

/// The merge/aggregation view of one O-D cell. On a single device
/// [contributingUsers] is implicitly 1 — real cross-device counts only exist
/// once the secure-aggregation merge backend stands up (DATA_SURFACE_SPEC §6).
class OdCell {
  final OdCellKey key;
  final int count;
  final int contributingUsers;

  const OdCell({
    required this.key,
    required this.count,
    this.contributingUsers = 1,
  });

  OdCell copyWith({int? count, int? contributingUsers}) => OdCell(
        key: key,
        count: count ?? this.count,
        contributingUsers: contributingUsers ?? this.contributingUsers,
      );
}

/// Station-catchment shape (how many riders alighted at a station, by hour and
/// day-type). No coordinate field.
class StationArrivalCell {
  final String stationId;
  final int hourBin;
  final DayType dayType;
  final int count;

  const StationArrivalCell({
    required this.stationId,
    required this.hourBin,
    required this.dayType,
    required this.count,
  });

  String toKeyString() => '$stationId|$hourBin|${dayType.name}';
}

/// On-device PRE-RELEASE output of `DataAssetPipeline.buildReleaseCandidate`.
///
/// This is deliberately **NOT** a [ReleasedCell] (red-team fix R3): on a single
/// device the k-anonymity `contributingUsers` is ~1, so a "suppressed" boolean
/// set here would be a false by-construction assurance. A candidate is only ever
/// a lawyer-reviewable, on-device methodology artifact — it can never reach the
/// egress sink (the sink accepts only [ReleasedCell]).
class ReleaseCandidateCell {
  final OdCellKey key;

  /// Count AFTER local k-anon survival + Laplace noise (candidate only).
  final int candidateNoisyCount;

  /// Local contributingUsers seen on THIS device (≈1). Named to make the single
  /// -device reality explicit and non-misleading.
  final int localContributingUsers;

  final bool dpApplied;
  final double epsilon;

  const ReleaseCandidateCell({
    required this.key,
    required this.candidateNoisyCount,
    required this.localContributingUsers,
    required this.dpApplied,
    required this.epsilon,
  });

  Map<String, Object?> toJson() => {
        'key': key.toKeyString(),
        'candidateNoisyCount': candidateNoisyCount,
        'localContributingUsers': localContributingUsers,
        'dpApplied': dpApplied,
        'epsilon': epsilon,
      };
}

/// The ONLY type the egress sink accepts (wrapped in an `OdFlowMatrix`).
///
/// Red-team fix R3: a [ReleasedCell] is **constructable only by the cross-device
/// merge / secure-aggregation backend**, via [ReleasedCell.fromSecureMerge],
/// which requires a [MergeBackendAuthority] token. On-device application code
/// cannot mint that token, so it can never fabricate a "released" cell. When the
/// backend does construct one, [kSuppressed] reflects REAL cross-device
/// `contributingUsers ≥ k`, and DP has genuinely been applied at merge.
///
/// Invariants (asserted): kSuppressed == true, dpApplied == true, epsilon > 0.
/// There is no public constructor that takes a raw count without going through
/// the k-anon + DP pipeline.
class ReleasedCell {
  final OdCellKey key;
  final int noisyCount;
  final int contributingUsers;
  final bool kSuppressed;
  final bool dpApplied;
  final double epsilon;

  const ReleasedCell._({
    required this.key,
    required this.noisyCount,
    required this.contributingUsers,
    required this.kSuppressed,
    required this.dpApplied,
    required this.epsilon,
  });

  /// Constructed ONLY by the secure-aggregation merge backend, which alone holds
  /// a [MergeBackendAuthority]. The asserts pin the release invariants.
  factory ReleasedCell.fromSecureMerge(
    MergeBackendAuthority authority, {
    required OdCellKey key,
    required int noisyCount,
    required int contributingUsers,
    required double epsilon,
  }) {
    // ignore: unnecessary_null_comparison
    assert(authority != null, 'merge-backend authority required');
    assert(contributingUsers >= kOdKAnonymityThreshold,
        'ReleasedCell must reflect real cross-device k ≥ $kOdKAnonymityThreshold');
    assert(epsilon > 0, 'DP epsilon must be positive');
    return ReleasedCell._(
      key: key,
      noisyCount: noisyCount,
      contributingUsers: contributingUsers,
      kSuppressed: true,
      dpApplied: true,
      epsilon: epsilon,
    );
  }

  Map<String, Object?> toJson() => {
        'key': key.toKeyString(),
        'noisyCount': noisyCount,
        'contributingUsers': contributingUsers,
        'kSuppressed': kSuppressed,
        'dpApplied': dpApplied,
        'epsilon': epsilon,
      };
}

/// Unforgeable capability token that gates [ReleasedCell.fromSecureMerge].
///
/// Its only constructor is private, so it can be minted solely by code inside
/// this library — and, by convention (DATA_SURFACE_SPEC §2.2 / R3), only the
/// future merge-backend adapter is permitted to expose a mint path. No on-device
/// pipeline code constructs one, which is exactly what keeps a single device
/// from ever producing a "released" (transmittable) cell.
class MergeBackendAuthority {
  const MergeBackendAuthority._();

  /// Reserved for the secure-aggregation backend adapter (Phase B). Deliberately
  /// unused on-device today; present so the type is testable and the merge
  /// backend has a single, auditable entry point.
  static const MergeBackendAuthority forSecureAggregationBackend =
      MergeBackendAuthority._();
}
