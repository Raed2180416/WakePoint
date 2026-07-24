# GeoWake — Privacy & Data Architecture

> How GeoWake handles user data: consent, differential privacy, k-anonymity, and the data asset pipeline.

---

## Principles

1. **Consent is default-OFF** — no data leaves the device without explicit user opt-in
2. **Coordinate-free aggregation** — no GPS coordinates in aggregate data, only station ID pairs
3. **Differential privacy** — Laplace noise added to every cell before egress
4. **K-anonymity** — cells with fewer than k contributions are suppressed
5. **Contribution capping** — per-device contribution limits per time window
6. **On-device erasure** — withdrawing consent erases all local aggregate data
7. **Fail-open** — pipeline errors never affect the core alarm

---

## Consent Service

**`lib/services/data_asset/mobility_consent_service.dart`**

### State Machine

```
Default (OFF) ──grant()──→ Enabled ──withdraw()──→ Disabled + on-device erasure
     ↑                          │
     └──notice version change───┘
        (forces re-consent)
```

### Key Properties

- `isSharingEnabled` — `true` only if `_enabled && _noticeVersion == kConsentNoticeVersion`
- `grant()` — records explicit opt-in with timestamp + notice version
- `withdraw()` — disables sharing, records withdrawal timestamp, triggers `onWithdraw` callback
- `consentReceiptJson()` — exports JSON proof of consent (app, purpose, timestamps, DP params)

### Persistence

Single key `gw_mobility_consent_v1` in SharedPreferences. Fail-safe parsing: any corruption defaults to disabled.

### Notice Versioning

`kConsentNoticeVersion` — when the privacy notice changes, this version bumps. Users must re-consent; old consent is treated as disabled.

---

## Data Asset Pipeline

**`lib/services/data_asset/data_asset_pipeline.dart`**

### Flow

```
Tracking session ends
        ↓
   OD aggregator          Counts origin→destination transitions
        ↓
   Station binner         Groups by station catchment areas
        ↓
   K-anonymity filter     Suppresses cells with < k=5 contributions
        ↓
   Differential privacy   Adds Laplace noise (ε per cell)
        ↓
   Contribution cap       Limits per-device contributions per window
        ↓
   ReleaseCandidateMatrix Output (post-DP, pre-merge)
        ↓
   HTTP egress sink       Uploads to backend merge engine
```

### Compile-Time Gate

`kDataAssetEgressEnabled` — when false, the egress sink is a no-op. This allows shipping the pipeline code with egress disabled until the backend is ready.

### Consent Gate

The pipeline checks `consentOrNull?.isSharingEnabled` before any egress. No consent = no upload. The pipeline still aggregates on-device (for when consent is granted later), but never sends data off-device.

### Fail-Open

All pipeline errors are swallowed. A pipeline failure must never:
- Crash the app
- Delay or prevent arming
- Affect the alarm delivery
- Block the tracking service

---

## Data Structures

**`lib/services/data_asset/od_cell.dart`**

All structures are **coordinate-free** — they reference stations by ID, not by lat/lng. This prevents re-identification from the aggregate data.

| Structure | Purpose |
|-----------|---------|
| `OdCellKey` | Origin-destination station ID pair |
| `OdCell` | Raw transition count |
| `StationArrivalCell` | Station arrival aggregate |
| `ReleaseCandidateCell` | Post-DP, pre-merge cell |
| `ReleasedCell` | Final released aggregate (only constructable by backend merge engine) |

`ReleasedCell` has a private constructor — it can only be created by the backend's `mergeEngine.js`, ensuring no client can forge released data.

---

## Differential Privacy

**`lib/services/data_asset/differential_privacy.dart`**

- **Mechanism:** Laplace noise
- **Parameter:** ε (epsilon) per cell — `kEpsilonPerCell`
- **Sensitivity:** 1 (each device contributes at most 1 count per cell per window)
- **Noise:** `Laplace(0, 1/ε)` added to each cell count

Lower ε = more noise = more privacy. The parameter is tuned to provide useful aggregate signal while protecting individual users.

---

## K-Anonymity

**`lib/services/data_asset/k_anonymity_filter.dart`**

- **Threshold:** `kOdKAnonymityThreshold` (default: 5)
- **Rule:** Any cell with fewer than k contributions is suppressed (not released)
- **Purpose:** Prevents re-identification of rare routes taken by few individuals

---

## Contribution Capping

**`lib/services/data_asset/contribution_cap.dart`**

Limits the number of cells a single device can contribute per time window. This prevents a single malicious device from dominating any cell and skewing the aggregate.

---

## Backend Merge Engine

**`geowake-server/src/utils/mergeEngine.js`**

1. Receives `ReleaseCandidateMatrix` from devices
2. Merges across devices (summing noisy counts)
3. Applies k-anonymity at the aggregate level
4. Builds dashboard summary, flow matrix, catchment report
5. Exposes public dashboard endpoints (no PII, aggregate-only)

Data is in-memory only — no persistent storage. Resets on server restart.

---

## What Data GeoWake Does NOT Collect

- **No GPS coordinates** in aggregate data (only station ID pairs)
- **No personal identifiers** (no name, email, phone number)
- **No device identifiers** in released data (device ID used only for contribution capping, stripped before release)
- **No browsing history, contacts, or photos**
- **No telemetry without explicit configuration** — `GEOWAKE_TELEMETRY_URL` defaults to empty (local-only)

---

## Legal Framework

GeoWake's data architecture is designed for compliance with:

- **DPDP Act 2023 (India)** — consent-based, purpose-limited, erasure on withdrawal
- **GDPR (if expanded to EU)** — lawful basis via consent, data minimization, right to erasure

The consent receipt (`consentReceiptJson()`) provides auditable proof of consent with timestamps and DP parameters.
