// lib/services/data_asset/aggregate_schema.dart
//
// GeoWake — the PII-free, sellable aggregate schema (DATA_SURFACE_SPEC §2.8).
//
// The only shapes that could ever be transmitted. Every field is a station
// token, an hour, a day-type, a noised count, or a DP/k disclosure value. There
// is NO device id, NO user id, and NO coordinate anywhere in these types.
//
//   • OdFlowMatrix          — flagship O-D flow, a list of ReleasedCell. The ONLY
//                             thing the egress sink accepts. ReleasedCell is
//                             constructable only by the merge backend (R3), so an
//                             OdFlowMatrix cannot be fabricated on-device.
//   • ReleaseCandidateMatrix — on-device methodology artifact, a list of
//                             ReleaseCandidateCell. Produced by
//                             buildReleaseCandidate; NEVER accepted by egress.
//   • CatchmentReport       — station-catchment shape.

import 'data_asset_config.dart';
import 'differential_privacy.dart';
import 'od_cell.dart';

/// The sellable O-D flow matrix. Wraps only [ReleasedCell]s — merge-backend
/// output. This is the sole payload type the egress sink will accept.
class OdFlowMatrix {
  final String schemaVersion;
  final List<ReleasedCell> cells;
  final double dpEpsilon;
  final int kThreshold;

  /// Optional inclusive hour-bin range covered (null = unrestricted).
  final int? hourBinStart;
  final int? hourBinEnd;

  const OdFlowMatrix({
    required this.cells,
    this.schemaVersion = kAggregateSchemaVersion,
    this.dpEpsilon = kEpsilonPerCell,
    this.kThreshold = kOdKAnonymityThreshold,
    this.hourBinStart,
    this.hourBinEnd,
  });

  Map<String, Object?> toJson() => {
        'schemaVersion': schemaVersion,
        'dpEpsilon': dpEpsilon,
        'kThreshold': kThreshold,
        'hourBinStart': hourBinStart,
        'hourBinEnd': hourBinEnd,
        'dpDisclosure': LaplaceMechanism.dpDisclosure(),
        'cells': cells.map((c) => c.toJson()).toList(),
      };
}

/// On-device pre-release methodology matrix. A list of [ReleaseCandidateCell]
/// (NOT ReleasedCell) — it can never be handed to the egress sink. Used by the
/// debug/methodology view and, in Phase B, as the input the merge backend turns
/// into a true [OdFlowMatrix].
class ReleaseCandidateMatrix {
  final String schemaVersion;
  final List<ReleaseCandidateCell> cells;
  final double dpEpsilon;
  final int kThreshold;

  const ReleaseCandidateMatrix({
    required this.cells,
    this.schemaVersion = kAggregateSchemaVersion,
    this.dpEpsilon = kEpsilonPerCell,
    this.kThreshold = kOdKAnonymityThreshold,
  });

  Map<String, Object?> toJson() => {
        'schemaVersion': schemaVersion,
        'candidate': true,
        'dpEpsilon': dpEpsilon,
        'kThreshold': kThreshold,
        'dpDisclosure': LaplaceMechanism.dpDisclosure(),
        'cells': cells.map((c) => c.toJson()).toList(),
      };
}

/// Station-catchment report shape (DATA_SURFACE_SPEC §2(b)). Merge-backend
/// output; carries only station tokens + noised counts.
class CatchmentReport {
  final String schemaVersion;
  final List<ReleasedCatchmentCell> cells;
  final double dpEpsilon;
  final int kThreshold;

  const CatchmentReport({
    required this.cells,
    this.schemaVersion = kAggregateSchemaVersion,
    this.dpEpsilon = kEpsilonPerCell,
    this.kThreshold = kMinContributingUsersCatchment,
  });

  Map<String, Object?> toJson() => {
        'schemaVersion': schemaVersion,
        'dpEpsilon': dpEpsilon,
        'kThreshold': kThreshold,
        'cells': cells.map((c) => c.toJson()).toList(),
      };
}

/// A released catchment cell (noised station arrival count). No coordinate.
class ReleasedCatchmentCell {
  final String stationId;
  final int hourBin;
  final DayType dayType;
  final int noisyCount;

  const ReleasedCatchmentCell({
    required this.stationId,
    required this.hourBin,
    required this.dayType,
    required this.noisyCount,
  });

  Map<String, Object?> toJson() => {
        'stationId': stationId,
        'hourBin': hourBin,
        'dayType': dayType.name,
        'noisyCount': noisyCount,
      };
}
