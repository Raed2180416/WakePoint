// lib/services/data_asset/data_asset_pipeline.dart
//
// GeoWake — orchestrator for the opt-in aggregate mobility data surface
// (DATA_SURFACE_SPEC §2.12). Assembled in main.dart after Hive init, like
// MonetizationService.
//
// The single integration call, `onTripCompleted`, is invoked UNAWAITED and
// FAIL-OPEN from post-arrival teardown (off the alarm/wake/lock path). Guard
// order is load-bearing:
//   1. `if (!consent.isSharingEnabled) return;`  ← default-OFF short-circuit,
//      FIRST, before any coordinate is touched.
//   2. bin BOTH endpoints (coords die inside StationBinner; R2).
//   3. aggregator.recordTrip(...) — counts only.
// The whole body is try/caught, so a data-surface failure can never influence
// teardown or the core spine.
//
// `buildReleaseCandidate` runs snapshot → k-anon → Laplace and emits a
// ReleaseCandidateMatrix (ReleaseCandidateCell, NOT ReleasedCell; R3). It NEVER
// uploads. Egress is doubly OFF: kDataAssetEgressEnabled == false AND the only
// wired sink is NullEgressSink.

import 'dart:developer' as dev;

import 'aggregate_egress_sink.dart';
import 'aggregate_schema.dart';
import 'contribution_cap.dart';
import 'data_asset_config.dart';
import 'differential_privacy.dart';
import 'http_candidate_egress_sink.dart';
import 'k_anonymity_filter.dart';
import 'mobility_consent_service.dart';
import 'od_aggregator.dart';
import 'od_cell.dart';
import 'station_binner.dart';

class DataAssetPipeline {
  DataAssetPipeline._();
  static final DataAssetPipeline instance = DataAssetPipeline._();

  MobilityConsentService? _consent;
  OdAggregator? _aggregator;
  StationBinner? _binner;
  AggregateEgressSink _sink = const NullEgressSink();
  CandidateEgressSink _candidateSink = const NullCandidateEgressSink();
  final LaplaceMechanism _laplace = LaplaceMechanism();

  int _nowMs() => DateTime.now().millisecondsSinceEpoch;

  bool _ready = false;
  bool get isReady => _ready;

  MobilityConsentService? get consentOrNull => _consent;

  /// Assemble the pipeline. Safe to call once at app start; fail-open — if
  /// anything throws the pipeline simply stays not-ready and every entry point
  /// short-circuits.
  ///
  /// Egress bright line: while [kDataAssetEgressEnabled] is false, the ONLY
  /// permitted sink is a [NullEgressSink]. Passing any other sink is a
  /// programming error and is asserted against.
  Future<void> init({
    MobilityConsentService? consent,
    OdAggregator? aggregator,
    StationBinner? binner,
    AggregateEgressSink? sink,
    CandidateEgressSink? candidateSink,
  }) async {
    try {
      final effectiveSink = sink ?? const NullEgressSink();
      assert(
        kDataAssetEgressEnabled || effectiveSink is NullEgressSink,
        'Egress is OFF (kDataAssetEgressEnabled=false): only NullEgressSink may '
        'be wired. Refusing to construct a transmitting sink.',
      );
      _sink = effectiveSink;
      _candidateSink = candidateSink ?? const NullCandidateEgressSink();

      final agg = aggregator ?? OdAggregator(cap: ContributionCap());
      final cons = consent ?? MobilityConsentService();
      // Wire one-tap withdrawal to on-device erasure + auditable log.
      cons.onWithdraw ??= () => agg.wipeAndLogErasure(atMs: _nowMs());

      _aggregator = agg;
      _consent = cons;
      _binner = binner ?? StationBinner.fromShippedCatalogue();

      await cons.load();
      _ready = true;
    } catch (e) {
      _ready = false;
      dev.log('DataAssetPipeline init failed (staying inert): $e',
          name: 'DataAssetPipeline');
    }
  }

  /// THE single integration point. Unawaited + fail-open. Off the alarm path.
  ///
  /// Consent-off short-circuit is line one: with sharing disabled this makes
  /// ZERO Hive writes and never touches a coordinate.
  Future<void> onTripCompleted({
    required double originLat,
    required double originLng,
    required double destLat,
    required double destLng,
    required int epochMs,
    required int tzOffsetMinutes,
  }) async {
    try {
      final consent = _consent;
      final aggregator = _aggregator;
      final binner = _binner;
      if (!_ready || consent == null || aggregator == null || binner == null) {
        return;
      }
      // (1) DEFAULT-OFF SHORT-CIRCUIT — must be first.
      if (!consent.isSharingEnabled) return;

      // (2) Bin BOTH endpoints (R2). Raw coords live only as locals inside bin().
      final origin = binner.bin(
        lat: originLat,
        lng: originLng,
        epochMs: epochMs,
        tzOffsetMinutes: tzOffsetMinutes,
      );
      final destination = binner.bin(
        lat: destLat,
        lng: destLng,
        epochMs: epochMs,
        tzOffsetMinutes: tzOffsetMinutes,
      );
      // Either endpoint unmatched ⇒ un-aggregatable ⇒ drop (safe).
      if (origin == null || destination == null) return;

      // (3) Record counts. localDate derived from the trip's own local time.
      final localDate = _localDateString(epochMs, tzOffsetMinutes);
      await aggregator.recordTrip(
        origin: origin,
        destination: destination,
        localDate: localDate,
      );
    } catch (e) {
      // Fail-open: a data-surface failure never influences teardown.
      dev.log('onTripCompleted swallowed: $e', name: 'DataAssetPipeline');
    }
  }

  /// Builds the on-device methodology candidate: snapshot → k-anon suppress →
  /// Laplace noise per surviving cell. Emits [ReleaseCandidateCell]s (NOT
  /// ReleasedCell; R3). NEVER uploads — there is no call to any sink here.
  Future<ReleaseCandidateMatrix> buildReleaseCandidate({
    DpParams params = DpParams.stated,
  }) async {
    final aggregator = _aggregator;
    if (aggregator == null) {
      return const ReleaseCandidateMatrix(cells: []);
    }
    try {
      final snapshot = await aggregator.snapshot();
      final survivors = KAnonymityFilter.suppress(snapshot);
      final cells = <ReleaseCandidateCell>[];
      for (final cell in survivors) {
        final noisy = _laplace.noisyCount(
          cell.count,
          epsilon: params.epsilonPerCell,
          sensitivity: params.sensitivity,
        );
        cells.add(ReleaseCandidateCell(
          key: cell.key,
          candidateNoisyCount: noisy,
          localContributingUsers: cell.contributingUsers,
          dpApplied: true,
          epsilon: params.epsilonPerCell,
        ));
      }
      return ReleaseCandidateMatrix(cells: cells);
    } catch (e) {
      dev.log('buildReleaseCandidate failed: $e', name: 'DataAssetPipeline');
      return const ReleaseCandidateMatrix(cells: []);
    }
  }

  /// The currently wired egress sink (always [NullEgressSink] while egress is
  /// OFF). Exposed for the tripwire test.
  AggregateEgressSink get wiredSink => _sink;

  /// The currently wired candidate egress sink.
  CandidateEgressSink get wiredCandidateSink => _candidateSink;

  /// Builds a release candidate on-device and uploads it to the backend merge
  /// engine via the candidate egress sink. Consent-gated: does nothing if
  /// sharing is disabled. Fail-open: swallows all errors.
  Future<void> uploadCandidate() async {
    try {
      final consent = _consent;
      if (!_ready || consent == null) return;
      if (!consent.isSharingEnabled) return;

      final candidate = await buildReleaseCandidate();
      if (candidate.cells.isEmpty) return;

      await _candidateSink.uploadCandidate(candidate);
    } catch (e) {
      dev.log('uploadCandidate swallowed: $e', name: 'DataAssetPipeline');
    }
  }

  /// Local `YYYY-MM-DD` for the trip's own wall clock (UTC-shifted by tzOffset).
  static String _localDateString(int epochMs, int tzOffsetMinutes) {
    final local = DateTime.fromMillisecondsSinceEpoch(
      epochMs + tzOffsetMinutes * 60000,
      isUtc: true,
    );
    final y = local.year.toString().padLeft(4, '0');
    final m = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }
}
