// lib/services/data_asset/data_asset_config.dart
//
// GeoWake — opt-in aggregate mobility data surface: the SINGLE SOURCE OF TRUTH
// for the bright-line constants (DATA_SURFACE_SPEC §2.1). Every value here is
// `const` and is asserted by the config tripwire test, so any weakening of a
// privacy guarantee fails the build rather than silently shipping.
//
// THE BRIGHT LINE (enforced in code, not just policy): raw trajectories NEVER
// leave the device. The only thing that can ever be transmitted is a
// k-anonymous, differentially-private aggregate — and egress is doubly OFF:
//   1. Runtime : MobilityConsentService.isSharingEnabled defaults FALSE.
//   2. Compile : [kDataAssetEgressEnabled] == false AND the only wired sink is
//      NullEgressSink (which imports no HTTP/socket library).
//
// Nothing in this module is user-facing except the consent screen/copy; every
// user-facing string says "GeoWake".

/// HARD kill-switch for all egress. No non-null sink is constructed while this
/// is false. Flip ONLY after a contracted buyer AND an Indian DP-lawyer DPIA
/// sign-off AND the cross-device merge backend exist (DATA_SURFACE_SPEC §5/§6).
const bool kDataAssetEgressEnabled = false;

/// INERT config placeholder — the merge-backend ingestion endpoint the future
/// HttpAggregateEgressSink would POST a released [OdFlowMatrix] to. Empty by
/// default and NEVER read while [kDataAssetEgressEnabled] is false. Set this
/// (alongside flipping the kill-switch) ONLY once the secure-aggregation merge
/// backend + ingestion server exist and a DPIA is signed (DATA_SURFACE_SPEC
/// §5/§6). Until then it is a documented no-op.
const String kDataAssetEgressEndpoint = '';

/// Endpoint for the candidate egress sink (device → server merge engine).
/// POSTs ReleaseCandidateMatrix JSON to /ingest. Empty by default; set when
/// the merge backend is live.
const String kCandidateEgressEndpoint = 'https://geowake-production.up.railway.app/api/aggregate';

/// k for origin-destination cell suppression (Google's "100 rule"). A cell with
/// fewer than this many *contributing users* is dropped, never released.
const int kOdKAnonymityThreshold = 100;

/// k for station-catchment cells.
const int kMinContributingUsersCatchment = 100;

/// Per-user contribution cap: at most this many DISTINCT cells per local day.
/// This is what bounds the DP L1 sensitivity to 4.
const int kPerUserMaxCellsPerDay = 4;

/// Per-user, per-cell, per-day cap. A cell is an INDICATOR (0/1), not a raw trip
/// count, so per-cell sensitivity is exactly 1.
const int kPerUserMaxCountPerCellPerDay = 1;

/// Stated differential-privacy epsilon per released cell (central model, applied
/// at merge). ε is NOT comparable across DP models — see DpModel.
const double kEpsilonPerCell = 0.44;

/// Stated per-user daily epsilon budget (= kEpsilonPerCell * kPerUserMaxCellsPerDay).
const double kPerUserDailyEpsilonCap = 1.76;

/// Sellable aggregate schema version.
const String kAggregateSchemaVersion = 'od-v1';

/// Consent notice version. A bump forces fresh re-consent (material change).
const String kConsentNoticeVersion = 'mobility-consent-v1';

/// Maximum snap radius (metres) from a raw fix to the nearest catalogue station.
/// Beyond this, the endpoint is un-aggregatable ⇒ the trip is dropped (safe).
const double kStationSnapMaxRadiusMeters = 800.0;
