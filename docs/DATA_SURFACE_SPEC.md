# DATA_SURFACE_SPEC.md

**Opt-in aggregate mobility data surface — implementation-ready, legal-by-construction.**

Status: SHIP THE SCAFFOLD NOW (guardrails on, egress OFF). Books $0. No bytes leave the device.
Schema: `od-v1` · Consent notice: `mobility-consent-v1` · App name in all user-facing strings: **GeoWake**.
Supersedes nothing; adds a new self-contained module `lib/services/data_asset/`. Preserves every `DATA_STRATEGY.md` guardrail.

---

## 1. The bright line + the invariant the code enforces

### The bright line
**Raw trajectories NEVER leave the device.** The only thing that can ever be sold or transmitted is a
**k-anonymous, differentially-private aggregate** — station×hour origin-destination counts and station catchment
counts, with statistical noise added and every small group suppressed. Contribution is **opt-in and default-OFF**;
withdrawal is one tap and erases on-device state immediately.

### The invariant the code enforces (type-level, not just policy)
1. **No aggregate type carries a coordinate.** `OdCellKey`, `OdCell`, `StationArrivalCell`, `TripEndpoint`,
   `ReleasedCell` have **no `double` lat/lng field**. A trajectory is *not representable* at the aggregation or
   upload boundary.
2. **Raw lat/lng exists only as a function-local variable** inside exactly one function (`StationBinner.bin`),
   is read to compute an opaque station token, then goes out of scope. Never persisted, returned, or logged.
3. **The egress sink accepts only pipeline-produced `ReleasedCell` values** wrapped in an `OdFlowMatrix`. There is
   no raw-count overload. An un-noised count or a coordinate cannot reach `upload(...)`.
4. **Two independent gates guard egress**, either of which alone blocks all transmission:
   - **Runtime**: `MobilityConsentService.isSharingEnabled` (default **FALSE**), checked as line one of
     `onTripCompleted` and again before any release build.
   - **Compile-time**: `const kDataAssetEgressEnabled = false`, and the only wired sink is `NullEgressSink`. The
     egress file imports **no HTTP/socket library** — there is literally no code path to transmit a byte.
5. **The core is untouched.** `PremiumService` is never consulted; the never-late alarm, accuracy, underground
   reliability, and basic share are identical whether sharing is on or off. The single integration call is
   unawaited, fail-open, and fires at post-arrival teardown — off the alarm/wake/lock path.

> Today's leak surface = **zero**. The scaffold is safe to ship because egress is doubly, non-bypassably OFF.

---

## 2. Architecture

New module, all-new files. The **only** edits to existing files: one unawaited fire-and-forget call in the
trip-completion path, one Settings-drawer tile, and `main.dart` init.

```
lib/services/data_asset/
  data_asset_config.dart          §2.1  bright-line const flags
  od_cell.dart                    §2.2  coordinate-free aggregate types
  station_binner.dart             §2.3  ONLY place coordinates are touched
  contribution_cap.dart           §2.4  DP L1-sensitivity bound
  od_aggregator.dart              §2.5  on-device counts DB
  k_anonymity_filter.dart         §2.6  small-group suppression
  differential_privacy.dart       §2.7  Laplace mechanism + disclosure
  aggregate_schema.dart           §2.8  PII-free sellable schema
  aggregate_egress_sink.dart      §2.9  upload contract (NullEgressSink only)
  mobility_consent_service.dart   §2.10 default-OFF DPDP Rule-3 consent
  mobility_consent_copy.dart      §2.11 standalone notice copy
  data_asset_pipeline.dart        §2.12 orchestrator
lib/screens/
  mobility_data_consent_screen.dart     standalone consent UI
  settingsdrawer.dart (edit)            one new ListTile
lib/debug/
  od_aggregate_debug_view.dart          optional, methodology inspector (zero egress)
```

### 2.1 Config / bright-line flags — `data_asset_config.dart`
Single source of truth, all `const`. Asserted by a CI tripwire test so any weakening fails the build.

| Const | Value | Meaning |
|---|---|---|
| `kDataAssetEgressEnabled` | `false` | HARD kill-switch. No sink is constructed while false. Flip only after a contracted buyer **and** lawyer sign-off. |
| `kOdKAnonymityThreshold` | `100` | k for O-D suppression (Google's 100 rule). |
| `kMinContributingUsersCatchment` | `100` | k for catchment cells. |
| `kPerUserMaxCellsPerDay` | `4` | contribution cap → bounds DP L1 sensitivity to 4. |
| `kPerUserMaxCountPerCellPerDay` | `1` | indicator, not a raw trip count → per-cell sensitivity = 1. |
| `kEpsilonPerCell` | `0.44` | stated ε per released cell (central model at merge). |
| `kPerUserDailyEpsilonCap` | `1.76` | stated per-user daily ε budget. |
| `kAggregateSchemaVersion` | `'od-v1'` | |
| `kConsentNoticeVersion` | `'mobility-consent-v1'` | |

### 2.2 Bright-line types — `od_cell.dart`
File header states: *"No field here is or derives from a coordinate. stationId is drawn from a fixed, enumerable
transit-stop catalogue — never a lat/lng and never a coordinate-derived token."*

- `enum DayType { weekday, weekend }` (holiday calendar later).
- `class OdCellKey { String originStationId; String destStationId; int hourBin; /*0–23 local*/ DayType dayType; }`
  — value type with `==`/`hashCode`; `toKeyString()` = `"$originStationId>$destStationId|$hourBin|${dayType.name}"`.
  **No double fields.**
- `class OdCell { OdCellKey key; int count; int contributingUsers; }` — merge view; on a single device
  `contributingUsers` is implicitly 1.
- `class StationArrivalCell { String stationId; int hourBin; DayType dayType; int count; }` — catchment shape.
- `class ReleaseCandidateCell` — on-device pre-release output of `buildReleaseCandidate`. **Not** a `ReleasedCell`
  (closes the false by-construction assurance; see §3-R3).
- `class ReleasedCell` — the **only** type the egress sink accepts. **Constructable only by the cross-device
  merge / secure-aggregation backend**, so `kSuppressed == true` reflects real cross-device `contributingUsers ≥ 100`,
  not a single-device flag. Asserted invariants: `kSuppressed == true`, `dpApplied == true`, `epsilon > 0`. No public
  constructor takes a raw count without going through the k-anon + DP pipeline.

### 2.3 Station binning (the ONLY place coordinates are touched) — `station_binner.dart`
`class StationBinner`:
```
TripEndpoint? bin({required double lat, required double lng,
                   required int epochMs, required int tzOffsetMinutes})
```
- Snaps `(lat,lng)` to the nearest **catalogue** station token using the existing transit-stop catalogue
  (`MetroStopService.TransitStop.placeId` / the ~100 m signature-cell scheme in `saved_route.dart buildSignature`).
- `stationId` is drawn **ONLY** from the finite, enumerable catalogue. **No geohash / coordinate-derived fallback**
  (see §3-R1). If no catalogue station is within max radius (e.g. 800 m) → return **null**. Unmatched =
  un-aggregatable = dropped = safe.
- `lat`/`lng` are function-local parameters — read to compute the token, then out of scope. Nothing
  coordinate-shaped is returned, stored, or logged.
- `hourBin = localHour(epochMs, tzOffsetMinutes)`; `dayType` from local weekday.
- `class TripEndpoint { String stationId; int hourBin; DayType dayType; }` — no coordinate field.

### 2.4 Contribution cap (DP sensitivity bound) — `contribution_cap.dart`
`class ContributionCap` over Hive box `gw_od_contribcap_v1`, keyed by local date:
- `bool tryReserve(OdCellKey key, {required String localDate})` → true iff this cell not already counted today
  (`kPerUserMaxCountPerCellPerDay = 1`) **and** the user is under `kPerUserMaxCellsPerDay = 4` distinct cells today.
- Rolls over per local day; prunes old days. Makes per-user L1 sensitivity provably ≤ 4 for the daily DP budget.

### 2.5 On-device aggregator — `od_aggregator.dart`
`class OdAggregator` over Hive box `gw_od_aggregate_v1` (`String cellKey → int count`):
- `Future<void> recordTrip({required TripEndpoint origin, required TripEndpoint destination, required int epochMs})`
  — build `OdCellKey`; check `ContributionCap.tryReserve`; if reserved, `box.put(key, (box.get(key) ?? 0) + 1)`.
  Also updates `gw_station_arrival_v1` (catchment). Holds **only counts**. Fail-open: whole body in try/catch,
  never throws (mirrors `TelemetryService._emit`).
- `Future<List<OdCell>> snapshot()`; `Future<void> wipe()` (clears both boxes; called on withdrawal).

### 2.6 k-anonymity — `k_anonymity_filter.dart`
Pure: `List<OdCell> suppress(Iterable<OdCell> cells, {int k = kOdKAnonymityThreshold})` → drops cells with
`contributingUsers < k`. Honest reality: on a single device `contributingUsers ≈ 1`, so this yields ~nothing until
cross-device merge exists — that is the v2 gate and the reason egress stays off. In the scaffold it runs over the
local snapshot to prove/validate the methodology (lawyer-reviewable).

### 2.7 Differential privacy — `differential_privacy.dart`
Pure `class LaplaceMechanism`:
- `int noisyCount(int trueCount, {required double epsilon, int sensitivity, Random? rng})` — Laplace(scale =
  sensitivity/epsilon) noise, then `clamp(0, round(...))`. Seedable RNG for deterministic tests.
- `DpParams { model: DpModel.central, epsilonPerCell: 0.44, perUserDailyEpsilon: 1.76,
  sensitivity: kPerUserMaxCountPerCellPerDay }` — the stated ε + model + contribution-bound triple.
- `enum DpModel { local, central }`. **Noise is applied in the central model at merge** (see §3-R4). Double-noising
  is forbidden; `dpDisclosure()` pins the mechanism (model + ε + sensitivity bound) for the buyer datasheet + DPIA,
  and the config tripwire test asserts it matches the stated constants.

### 2.8 Sellable schema — `aggregate_schema.dart`
- `class OdFlowMatrix { schemaVersion; hourBin/dayType range; List<ReleasedCell> cells; dpEpsilon; kThreshold; }`
  with `toJson()` — flagship, PII-free, station/line granularity shared with the telemetry schema.
- `class CatchmentReport` — §2(b) catchment shape.
- Only station tokens, hour, day-type, noised count, DP/k disclosure. **No device id, user id, or coordinate.**

### 2.9 Upload contract / egress (books $0, ships OFF) — `aggregate_egress_sink.dart`
- `abstract class AggregateEgressSink { Future<void> upload(OdFlowMatrix released); }` — the signature **is** the
  contract: accepts only an `OdFlowMatrix` of `ReleasedCell`, producible only by the merge backend's k-anon + DP
  pipeline. No raw-cell overload exists.
- `class NullEgressSink implements AggregateEgressSink { Future<void> upload(_) async {} }` — the **default and only
  wired** impl. No http/socket import in the file.
- `HttpAggregateEgressSink` is **not written now**. `DataAssetPipeline` refuses to construct any non-null sink while
  `kDataAssetEgressEnabled == false` (asserted in tests).

### 2.10 Consent service — `mobility_consent_service.dart`
`class MobilityConsentService` (DI + in-memory default like `PremiumService`), SharedPreferences key
`gw_mobility_consent_v1` — **separate** from `geowake_entitlement_v1` and any telemetry key:
- Blob `{ enabled: bool(default FALSE), noticeVersion, grantedAtMs, withdrawnAtMs }`. Fail-safe parse → DISABLED.
- `bool get isSharingEnabled` (false until explicit opt-in).
- `Future<void> grant()` — records enabled + version + timestamp; forces re-consent if
  `noticeVersion != kConsentNoticeVersion` (material change ⇒ fresh consent).
- `Future<void> withdraw()` — `enabled = false`, stamps `withdrawnAtMs`, calls `OdAggregator.wipe()` +
  ContributionCap clear + appends to `gw_od_erasure_log_v1` (DPDP s.8(7)/s.12 auditable erasure). One-tap, cease
  immediately.
- `String consentReceiptJson()` — exportable proof of the specific consent (Rule-3 evidence).

### 2.11 Consent copy — `mobility_consent_copy.dart`
Const strings, app name **GeoWake**. Standalone Rule-3 notice:
- **Title**: "Help improve transit planning — share anonymous trip stats".
- **Data itemised**: "Only counts of how many riders travelled between stations, by hour and weekday/weekend.
  Never your location trail, never your identity, never a single trip traceable to you."
- **Purpose**: "To build anonymous, aggregated station-to-station travel-flow statistics for transit authorities
  and urban planners."
- **Guarantees**: "Off by default. Your wake-alarm works exactly the same whether this is on or off. Turn it off any
  time in one tap — we stop immediately and delete what's stored on this device."
- **Method disclosure**: "We add statistical noise (differential privacy, ε per cell = 0.44) and never release any
  group smaller than 100 riders (k-anonymity)."
- **Grievance / DPO contact placeholder** + withdraw link + Data Protection Board complaint link.
- **Age line**: "You must be 18 or older to turn this on."

### 2.12 Orchestrator — `data_asset_pipeline.dart`
`class DataAssetPipeline` (singleton, assembled in `main.dart` after Hive init, like `MonetizationService`):
- `Future<void> init(...)` — wires `MobilityConsentService`, `OdAggregator`, `StationBinner`; asserts
  `!kDataAssetEgressEnabled || sink provided`; default sink `NullEgressSink`.
- `Future<void> onTripCompleted({originLat, originLng, destLat, destLng, epochMs, tzOffsetMinutes})` — guard order:
  `if (!consent.isSharingEnabled) return;` **FIRST** (default-off short-circuit) → bin **both** endpoints (coords die
  inside `StationBinner`; both snapped to catalogue tokens, see §3-R2) → `aggregator.recordTrip(...)`. Whole body
  try/caught, fail-open.
- `Future<OdFlowMatrix> buildReleaseCandidate()` — snapshot → `KAnonymityFilter.suppress` →
  `LaplaceMechanism.noisyCount` per surviving cell → `OdFlowMatrix`. Used by the debug/methodology view and (future)
  egress. **Never auto-uploads.** On-device it emits `ReleaseCandidateCell`, not `ReleasedCell`.

### Integration point (exactly one, additive)
In the trip-completion path — `lib/services/route_session_manager.dart` (or `active_route_manager.dart`) where
origin (boarding fix) and declared destination (RouteMemory lat/lng/line) are both known — add one fire-and-forget
call **after** the alarm fired and the session is closing (same moment as `AdPlacement.postArrival`), unawaited,
wrapped so it can never influence teardown:
```dart
// unawaited, fail-open — off the alarm path
DataAssetPipeline.instance.onTripCompleted(/* origin+dest lat/lng, epochMs, tzOffset */);
```

### On-device persistence (all NEW, none shared with alarm state)
| Store | Kind | Holds |
|---|---|---|
| `gw_od_aggregate_v1` | Hive | `String cellKey → int count` (counts only) |
| `gw_station_arrival_v1` | Hive | catchment counts |
| `gw_od_contribcap_v1` | Hive | per-local-day contribution bookkeeping (sensitivity bound) |
| `gw_od_erasure_log_v1` | Hive | auditable withdrawal/erasure records |
| `gw_mobility_consent_v1` | SharedPreferences | consent blob (separate from entitlement + telemetry) |
| raw lat/lng | — | **NEVER persisted**; function-local only inside `StationBinner.bin` |

**Android platform**: none required. No new permissions (reuses location already granted for the alarm), no
manifest change, no native bridge. All on-device Dart + Hive.

---

## 3. Privacy red-team findings + the MANDATORY fixes folded in

**Verdict: SAFE to ship the scaffold now** — the double, non-bypassable egress gate means zero bytes leave the
device, so today's leak surface is zero. The findings below are **latent** violations that become live only the
moment egress flips, which itself requires the flag **+** the deferred merge backend **+** the mandatory Indian-DP
lawyer DPIA. **Treat every required fix as a hard pre-egress gate, not a ship blocker.**

### Biggest risk (identified)
The `StationBinner` **geohash-cell fallback token** would have violated the bright line. A ~100 m geohash is a
**reversible** quantization of lat/lng — it *is* a coordinate, decodable to a 100 m square. That turns `OdCellKey`
into `origin-100m-cell > dest-100m-cell | hour | dayType` — a 3-point spatio-temporal trajectory. de Montjoye
(Nature, 2013; cited in `DATA_STRATEGY §5`) shows 2 points re-identify >50% of people and coarsening barely helps.
A rider's home-cell → work-cell at 08:00 weekday is near-unique. Compounding it: the by-construction k-anon claim is
only as strong as `contributingUsers`, which on a single device is always 1 — so `kSuppressed` would be a boolean
*set by the constructor*, not a proof of real cross-device k ≥ 100.

### MANDATORY fixes (folded into §2 above; all are hard pre-egress gates)
- **R1 — Delete the geohash fallback entirely.** `stationId` must be drawn **only** from the finite, enumerable
  transit-stop catalogue. No catalogue station within max radius → return `null` (dropped = safe). A bounded,
  low-cardinality token space is what makes k-suppression meaningful; an unbounded coordinate-derived token defeats
  it. **Test**: assert every emitted `stationId ∈ catalogue set`; reject any token that round-trips to a lat/lng.
  *(Folded into §2.3.)*
- **R2 — Snap BOTH endpoints to catalogue tokens.** Origin boarding-fix **and** the RouteMemory destination
  (a user-declared placeId/lat-lng of an exact building) must both be snapped inside `StationBinner`. Never let the
  raw destination pass through — that would be a precise re-identifying POI. *(Folded into §2.3 and §2.12.)*
- **R3 — `ReleasedCell` constructable only by the merge backend.** So `kSuppressed == true` reflects real
  cross-device `contributingUsers ≥ 100`. On-device `buildReleaseCandidate` produces a `ReleaseCandidateCell`
  (**not** a `ReleasedCell`), closing the false by-construction assurance. *(Folded into §2.2 and §2.12.)*
- **R4 — Pin where DP noise is applied.** Central model, at merge (`DpModel.central`); forbid double-noising. ε is
  not comparable across models — `dpDisclosure()` states the mechanism and the config tripwire test asserts it.
  *(Folded into §2.7.)*

### What holds up under adversarial pressure (keep as-is)
- Consent is genuinely DPDP-clean: separate key, default FALSE, fail-safe parse to DISABLED, one-tap `withdraw()`
  that wipes both aggregate boxes + contribcap + writes the erasure log (s.6(4)–(6), s.8(7), s.12), standalone
  Rule-3 notice with itemisation/purpose/withdraw/Board links.
- s.6(1) "unconditional" satisfied — `PremiumService` never consulted; alarm identical on/off.
- DP discipline is the correct Google-Mobility triple (ε = 0.44/cell, ε ≤ 1.76/user/day, cap ≤ 4 cells & ≤ 1
  count/cell/day), enforced by a config tripwire test.
- Core alarm/reliability untouched — single unawaited fail-open call at post-arrival teardown.

---

## 4. DPDP compliance checklist

| # | DPDP requirement | How this design meets it | Status |
|---|---|---|---|
| 1 | s.6(1) consent free/specific/informed/**unconditional** | Separate opt-in switch; `PremiumService` never consulted; alarm identical on/off | ✅ built |
| 2 | s.6(1) not a precondition of the service | Free and Pro users have identical access to opt in; nothing is gated | ✅ built |
| 3 | Rule-3 standalone notice, itemised | `mobility_consent_copy.dart`: data items + purpose + method + withdraw + Board link | ✅ built (placeholders §6) |
| 4 | s.6(4)–(6) easy withdrawal, as easy as giving | One-tap `withdraw()` in-screen | ✅ built |
| 5 | s.6(6) cease processing on withdrawal | `enabled = false`; short-circuit line one of `onTripCompleted` | ✅ built |
| 6 | s.8(7) erase on withdrawal | `OdAggregator.wipe()` + contribcap clear | ✅ built |
| 7 | s.12 right to erasure, auditable | `gw_od_erasure_log_v1` append on every withdrawal | ✅ built |
| 8 | Purpose limitation | Types carry only O-D/catchment counts; one PII-free vocabulary, two consent gates | ✅ built |
| 9 | Data minimisation | Counts only; coordinates never persisted; unmatched trips dropped | ✅ built |
| 10 | Storage limitation | Contribcap prunes old days; aggregate is standing counts, wiped on withdrawal | ✅ built |
| 11 | Anonymisation / re-identification risk | k-anon (k≥100) + central-model DP (ε=0.44/cell); **needs merge backend + DPIA** | ⏳ pre-egress |
| 12 | s.8(9)–(10) named grievance/DPO + Board complaint | Placeholders in copy | ⏳ founder §6 |
| 13 | s.9(3) children / age gate | 18+ self-attest checkbox scaffolded; **counsel to confirm sufficiency** | ⏳ founder §6 |
| 14 | DPIA documenting methodology + risk | Modules are lawyer-reviewable; **DPIA authored + signed before egress** | ⏳ founder §6 |
| 15 | Operational obligations bind 13 May 2027 | Build-now / egress-later sequencing aligns | ✅ on track |

---

## 5. Build order

> Guardrails now, book $0, egress OFF until a buyer + legal sign-off.

**Phase A — Ship the scaffold now (no egress, no buyer, no lawyer needed):**
1. `data_asset_config.dart` — all consts, `kDataAssetEgressEnabled = false`.
2. `od_cell.dart` — coordinate-free types; `ReleasedCell` merge-backend-only; `ReleaseCandidateCell` for on-device.
3. `station_binner.dart` — catalogue-only tokens, **no geohash fallback** (R1); both endpoints snapped (R2).
4. `contribution_cap.dart`, `od_aggregator.dart` — counts DB + sensitivity bound; fail-open.
5. `k_anonymity_filter.dart`, `differential_privacy.dart` — pure, seedable, central-model DP pinned (R4).
6. `aggregate_schema.dart`, `aggregate_egress_sink.dart` — `NullEgressSink` only, no HTTP import.
7. `mobility_consent_service.dart` + `mobility_consent_copy.dart` — default-OFF, one-tap withdraw + erasure log.
8. `data_asset_pipeline.dart` — orchestrator; default-off short-circuit; `buildReleaseCandidate` never uploads.
9. UI: `mobility_data_consent_screen.dart` + one Settings-drawer tile; optional `od_aggregate_debug_view.dart`.
10. Integration: one unawaited `onTripCompleted(...)` call at post-arrival teardown; `main.dart` init.
11. **Tests** (§below) all green, including the egress + config tripwires.

**Phase B — Pre-egress (blocked on §6 founder items; do NOT flip the flag before all land):**
12. Secure-aggregation / merge backend stands up; `ReleasedCell` becomes constructable only there.
13. Indian DP-lawyer DPIA + re-identification sign-off filed.
14. Grievance/DPO contact + Board complaint link replace placeholders; age-gate posture confirmed.
15. `HttpAggregateEgressSink` written; `kDataAssetEgressEnabled` flipped **only** with buyer contracted + sign-off.

**Tests (pure/deterministic, no device):** (1) bright-line — no double field on any aggregate type; `upload` accepts
only `OdFlowMatrix`. (2) StationBinner — correct token/hourBin/dayType; null outside radius; no lat/lng returned;
**every token ∈ catalogue**. (3) ContributionCap — caps at 1/cell & 4 cells/day; rolls over; prunes. (4) k-anon —
drops `<k`, keeps `≥k`, boundary at exactly k. (5) Laplace — seeded determinism; empirical mean ≈ true within
tolerance; negatives clamp to 0; scale = sensitivity/epsilon; `dpDisclosure()` states model+ε+bound. (6) Consent —
default DISABLED; corrupt/missing → DISABLED; grant/withdraw round-trip; noticeVersion bump forces re-consent;
withdraw clears both boxes AND writes erasure log. (7) Pipeline OFF — `onTripCompleted` with consent off makes ZERO
Hive writes. (8) Pipeline ON — capped count; `buildReleaseCandidate` runs end to end. (9) fail-open — throwing
binner/box never throws out of `onTripCompleted`. (10) **egress guard tripwire** — `kDataAssetEgressEnabled == false`
and only wired sink is `NullEgressSink`. (11) **config tripwire** — stated ε/k/cap equal the DP disclosure.

---

## 6. What needs the founder

1. **Secure-aggregation / merge backend** (deferred, not needed for the scaffold). k-anonymity is inherently
   cross-device (one phone's `contributingUsers ≈ 1`), so real k ≥ 100 suppression and the central-model DP budget
   can only be finalised where many devices' contributions merge (Google Federated-Analytics-style secure
   aggregation, or a trusted aggregator). Must exist **before** `kDataAssetEgressEnabled` is flipped.
2. **Indian data-protection lawyer sign-off** on the anonymisation methodology + re-identification risk assessment +
   consent architecture, documented as a **DPIA** — a hard prerequisite to any egress.
3. **Named grievance-contact / DPO email** and the **Data Protection Board complaint link** to replace the
   placeholders in `mobility_consent_copy.dart` (DPDP s.8(9)–(10)).
4. **Age-gate decision** — an 18+ self-attest checkbox is scaffolded; counsel to confirm it satisfies s.9(3) for a
   location app, or commit to verifiable parental consent before egress.
5. **A contracted buyer** for the aggregate O-D / catchment dataset, and the **aggregate-upload backend** that
   receives it. Nothing to procure for the on-device scaffold — hive, shared_preferences, crypto are already
   dependencies; no account/key/backend needed to ship the default-OFF, no-egress build today.
