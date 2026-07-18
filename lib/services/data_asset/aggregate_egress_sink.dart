// lib/services/data_asset/aggregate_egress_sink.dart
//
// GeoWake — the egress contract (DATA_SURFACE_SPEC §2.9). BOOKS $0, SHIPS OFF.
//
// THIS FILE IMPORTS NO HTTP / SOCKET / NETWORK LIBRARY. There is literally no
// code path here that can transmit a byte.
//
// The signature IS the contract: `upload` accepts only an [OdFlowMatrix] of
// [ReleasedCell] — a payload producible only by the merge backend's k-anon + DP
// pipeline (ReleasedCell.fromSecureMerge; red-team fix R3). There is NO raw-cell
// or raw-count overload, so an un-noised count or a coordinate cannot reach
// upload().
//
// The default AND only wired implementation is [NullEgressSink], a no-op. The
// real HttpAggregateEgressSink is deliberately NOT written now and must not be
// added until kDataAssetEgressEnabled is flipped (buyer contracted + DPIA signed
// + merge backend live — DATA_SURFACE_SPEC §5 Phase B).

import 'aggregate_schema.dart';

/// The upload contract. Implementations receive only a fully-released,
/// DP-noised, k-suppressed [OdFlowMatrix].
abstract class AggregateEgressSink {
  Future<void> upload(OdFlowMatrix released);
}

/// The default and ONLY wired sink: transmits nothing. No network import exists
/// in this file, so egress is off by construction, not just by flag.
class NullEgressSink implements AggregateEgressSink {
  const NullEgressSink();

  @override
  Future<void> upload(OdFlowMatrix released) async {
    // Intentionally empty. Zero bytes leave the device.
  }
}
