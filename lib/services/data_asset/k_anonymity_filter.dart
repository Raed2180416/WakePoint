// lib/services/data_asset/k_anonymity_filter.dart
//
// GeoWake — k-anonymity suppression (DATA_SURFACE_SPEC §2.6).
//
// Pure. Drops every cell whose `contributingUsers` is below k, keeping only
// groups large enough that no single rider is re-identifiable.
//
// HONEST REALITY: on a single device `contributingUsers ≈ 1`, so over a local
// snapshot this yields ~nothing until the cross-device merge backend exists —
// that is the v2 gate and precisely why egress stays OFF. In the scaffold it
// runs to prove/validate the methodology (lawyer-reviewable).

import 'data_asset_config.dart';
import 'od_cell.dart';

class KAnonymityFilter {
  const KAnonymityFilter._();

  /// Returns only the cells with `contributingUsers >= k`. Cells with fewer are
  /// suppressed (dropped). Boundary is inclusive at exactly k.
  static List<OdCell> suppress(
    Iterable<OdCell> cells, {
    int k = kOdKAnonymityThreshold,
  }) {
    return cells.where((c) => c.contributingUsers >= k).toList();
  }
}
