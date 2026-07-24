# GeoWake — Research: User Accounts, DI Framework, Backend Merge Engine, Maps Cost Strategy

> Deep research conducted Jul 2026. Covers four areas: user accounts (Phase 2,
> non-blocking for production), dependency injection for Flutter, persistent
> backend merge engine, and Maps API cost mitigation strategy.

---

## 1. User Accounts — Phase 2, Non-Blocking for Production

### 1.1 Decision

**User accounts are Phase 2 — non-blocking for production launch.**

The core alarm, tracking, monetization, and data asset pipeline all work
without user accounts today. Production launch proceeds with device-based auth.

The **sole reason** to add accounts later is: **let users link their Pro
purchase to an account so it transfers across devices** (reinstall, new phone,
switching from Android to Android). Without accounts, users must manually
"Restore purchase" via Play Store on each new device — which works but is
friction.

### 1.2 Current State (Production-Ready)

GeoWake currently uses **device-based JWT auth** — no user accounts:

- `ApiClient._authenticate()` sends `bundleId` to `/api/auth/token`
- Server signs a JWT with `{ bundleId, iss }`, expires in 24h
- Token stored in `SharedPreferences`
- Entitlement tied to Play Store account (IAP restore via `restorePurchases()`)
- Data asset contributions keyed by device ID only

**This is sufficient for production.** The `restorePurchases()` flow in
`IapPurchaseBackend` already handles cross-device entitlement via Google Play
Store account sync. Users on a new device just tap "Restore purchase."

### 1.3 What Accounts Add (Phase 2 — Post-Launch)

| Capability | Without Accounts (Now) | With Accounts (Phase 2) |
|-----------|----------------------|------------------------|
| Cross-device Pro | Manual "Restore purchase" tap | Automatic on sign-in |
| Guardian contacts | Re-setup on reinstall | Persisted, auto-restore |
| Settings sync | Lost on reinstall | Restored on login |
| Support/refund | No way to verify user | Phone = identity |
| Data asset attribution | Device ID only | User ID (still DP-protected) |

### 1.4 Phase 2 Architecture: Phone OTP (Zero-Cost Approach)

**Key constraint: keep it free.** No paid SMS gateway. No Firebase. No
infrastructure that adds monthly cost.

#### Free OTP Strategy: Google Play Services SMS Retriever API

Google provides the **SMS Retriever API** (free, no cost) that:
1. App requests phone number from user
2. Backend generates OTP, sends SMS via a **free tier** SMS provider
3. SMS Retriever API auto-detects the OTP without user typing
4. App sends OTP to backend for verification

**Free SMS providers with sufficient free tiers:**
- **Twilio** — free trial, but not sustainable
- **AWS SNS** — 100 free SMS/month (India)
- **MSG91** — 100 free OTP SMS on signup
- **Fast2SMS** — free tier for India

**Even cheaper: OTP-less via Google One Tap / Play Games sign-in**

Instead of SMS OTP, use **Google Sign-In** (zero cost, already available on
every Android phone):
1. User taps "Sign in with Google"
2. Google returns a verified email + Google ID token
3. Backend verifies the Google ID token (free, no SMS)
4. Backend creates/finds user by Google ID
5. Issues JWT

**This is the recommended approach — zero cost, zero SMS, zero DLT compliance.**
Every Android user already has a Google account. No phone number needed.

#### Backend Changes (Phase 2)

**New endpoints:**

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| POST | `/api/auth/google` | No | Verify Google ID token, return JWT |
| GET | `/api/auth/me` | JWT | Get current user profile |
| PUT | `/api/auth/me` | JWT | Update profile |
| POST | `/api/auth/link-purchase` | JWT | Link IAP purchase token to user |

**New database table (PostgreSQL — add when user accounts land):**

```sql
CREATE TABLE users (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  google_id     VARCHAR(64) UNIQUE NOT NULL,
  email         VARCHAR(255),
  name          VARCHAR(100),
  pro_linked    BOOLEAN DEFAULT FALSE,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_login    TIMESTAMPTZ
);

CREATE TABLE user_purchases (
  user_id       UUID REFERENCES users(id),
  purchase_token VARCHAR(200) NOT NULL,
  product_id    VARCHAR(100) NOT NULL,
  linked_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (user_id, purchase_token)
);
```

#### Flutter Changes (Phase 2)

**New packages:**
- `google_sign_in` — Google Sign-In (free, no SMS)
- `flutter_secure_storage` — store JWT securely

**New service: `AuthService`**

```dart
abstract class AuthService {
  Future<bool> signInWithGoogle();
  Future<void> signOut();
  User? get currentUser;
  String? get authToken;
  Future<void> linkPurchaseToAccount(String purchaseToken);
}
```

**Purchase linking flow:**
1. User signs in with Google → gets JWT
2. App sends IAP purchase token to `/api/auth/link-purchase`
3. Backend stores the link (user ↔ purchase token)
4. On new device: user signs in → backend returns `pro_linked: true` → app grants Pro

#### Migration Strategy

**Phase 1 (now — production launch):**
- No accounts. Device-based auth. IAP restore via Play Store.
- This works. Ship it.

**Phase 2 (post-launch, when justified):**
- Add Google Sign-In as optional ("Sign in to sync Pro across devices")
- If signed in, purchase links to account
- If not signed in, purchase stays on Play Store account (restore still works)
- **Accounts are always optional** — core alarm never requires login

**Phase 3 (if needed):**
- Phone OTP for users without Google accounts (adds SMS cost)
- Cloud sync of guardian contacts and settings

#### Privacy Impact

- Google Sign-In gives email + name — stored in PostgreSQL, never in aggregate data
- JWT contains `userId` (UUID), not email
- Data asset pipeline unchanged — still coordinate-free, still DP + k-anon
- Users can delete account + data (DPDP Act compliance)
- **No phone number collected unless Phase 3**

### 1.5 UPI Payment Flow (Already Implemented)

GeoWake's payment interface **already handles UPI payments correctly** via
Google Play Billing. Here's how it works today:

#### Current UPI Flow

```
User taps "Buy Pro ₹199"
        │
        ▼
Google Play Billing launches
        │
        ▼
User sees payment methods:
  ├── UPI (GPay, PhonePe, Paytm, BHIM, etc.)
  ├── Credit/Debit card
  ├── Net banking
  └── Wallet
        │
        ▼
User selects UPI app
        │
        ▼
Redirected to their preferred UPI app
(GPay / PhonePe / Paytm / BHIM / etc.)
        │
        ▼
User approves payment in UPI app
        │
        ├── If instant: PurchaseStatus.purchased → Pro unlocked immediately
        │
        └── If pending (UPI collection): PurchaseStatus.pending
                │
                ▼
            App shows "Payment processing…" banner
            (paywall_screen.dart — ValueListenableBuilder
             on pendingPurchasesListenable)
                │
                ▼
            User can close the screen — app keeps listening
                │
                ▼
            Payment clears (minutes to hours later)
                │
                ▼
            purchaseStream fires with PurchaseStatus.purchased
                │
                ▼
            Pro unlocked automatically — even if app was closed
            (IapPurchaseBackend._onPurchases handles this)
```

#### Key Implementation Details

1. **`IapPurchaseBackend`** (`@/home/raed/Projects/WakePoint/lib/services/monetization/purchase_backend_impl.dart`)
   - Long-lived `purchaseStream` listener catches late-arriving UPI payments
   - 5-minute timeout on `buyOneTime()` — but stream keeps listening after timeout
   - `queryPastPurchases()` on app launch catches UPI payments that cleared overnight
   - `pendingProductIds` tracked for UI feedback

2. **`MonetizationService`** (`@/home/raed/Projects/WakePoint/lib/services/monetization/monetization_service.dart`)
   - `pendingPurchasesListenable` — reactive `ValueNotifier<Set<String>>` for UI
   - `onPendingChanged` callback wired to UI banner
   - `onEntitlementChanged` fires when pending purchase clears → grants Pro

3. **Paywall screen** (`@/home/raed/Projects/WakePoint/lib/screens/monetization/paywall_screen.dart`)
   - Shows "Payment processing…" banner when UPI is pending
   - Snackbar: "Payment processing — Pro will unlock automatically once it clears"
   - Distinguishes cancel vs pending vs error

4. **`PremiumService`** (`@/home/raed/Projects/WakePoint/lib/services/monetization/premium_service.dart`)
   - `applyOwnedProducts()` — idempotent, grants Pro when late purchase arrives
   - One-time non-consumable purchase ( Indians prefer one-time over subscriptions)
   - Rewarded day-pass as free alternative (watch ad → Pro for 24h)

#### What This Means

**UPI payments already work.** When a user taps "Buy Pro":
1. Google Play shows all payment methods including UPI apps
2. User picks their preferred UPI app (GPay, PhonePe, Paytm, etc.)
3. Google Play redirects to that app for payment approval
4. If payment is instant → Pro unlocks immediately
5. If UPI is pending → "Payment processing" banner shows, Pro unlocks when it clears
6. If app was closed when payment cleared → Pro unlocks on next app launch

**No changes needed for production.** The implementation is already
production-ready for Indian UPI payments.

### 1.6 Cost Estimate (Phase 2 — When Accounts Land)

- **Google Sign-In:** $0 (free, no SMS)
- **PostgreSQL on Railway:** ~$5/month (512MB, sufficient for early stage)
- **No Redis needed** (Google Sign-In is stateless, no OTP sessions to store)
- **If phone OTP added (Phase 3):** MSG91 ~₹0.20-0.35/SMS, ~₹4K-7K/month at 10K users

---

## 2. Dependency Injection Framework for Flutter

### 2.1 Current State

GeoWake uses **hand-rolled singletons** everywhere:

```dart
// Pattern used across 15+ services
class MonetizationService {
  MonetizationService._();
  static final MonetizationService instance = MonetizationService._();
}
```

Services using this pattern:
- `ApiClient`, `TrackingService`, `NotificationService`, `MonetizationService`
- `AntiTheftService`, `DataAssetPipeline`, `HomeWidgetBridge`, `TelemetryService`
- `GuardianService`, `JourneyShareService`, `FollowedRidesService`, `RouteLogger`
- `RouteQueue`, `LocationManager`, `OfflineCoordinator`, `PostAlarmMulticast`
- `WidgetArmHandler`

**Problems with current approach:**
1. No abstraction — services reference concrete singletons, not interfaces
2. Testing requires `@visibleForTesting` hacks and `resetInstance()` patterns
3. Can't swap implementations (e.g., mock vs real ApiClient)
4. No lifecycle management — singletons live forever
5. Background isolate can't access main isolate's singletons (each isolate gets its own)
6. No dependency graph — initialization order is manual and fragile

### 2.2 Framework Comparison

| Feature | get_it | get_it + Injectable | Riverpod |
|---------|--------|---------------------|----------|
| Pattern | Service locator | Service locator + codegen | Reactive DI |
| BuildContext needed | No | No | Yes (for `ref`) |
| Background isolate | ✅ Works | ✅ Works | ❌ Needs ProviderScope |
| Code generation | No | Yes (build_runner) | Optional (riverpod_generator) |
| Compile-time safety | Runtime errors | Runtime errors | Compile-time |
| State management | No | No | Yes (reactive) |
| Learning curve | Low | Low-Medium | High |
| Boilerplate | Minimal | Minimal (auto-generated) | Medium |
| Testing | Easy (reset + re-register) | Easy | Easy (provider overrides) |
| Async init | `registerSingletonAsync` | `@preResolve` | `FutureProvider` |
| Scoping | Yes (scopes) | Yes | Yes (ProviderScope) |
| Bundle size | ~15KB | ~15KB + generated | ~50KB |

### 2.3 Recommendation: `get_it` + `Injectable`

**Why get_it + Injectable over Riverpod:**

1. **Background isolate compatibility** — GeoWake's `TrackingService` runs in a
   background isolate via `flutter_background_service`. `get_it` works in any isolate
   (each gets its own registry). Riverpod requires `ProviderScope` which is
   widget-tree-bound — can't use it in a background isolate.

2. **Minimal migration effort** — current codebase already uses the singleton pattern.
   `get_it` is a natural evolution: replace `MyService.instance` with `getIt<MyService>()`.
   The mental model is identical.

3. **No BuildContext dependency** — services like `TrackingService`, `NotificationService`,
   and `TelemetryService` operate outside the widget tree. `get_it` doesn't need context.

4. **Injectable eliminates boilerplate** — annotate classes with `@lazySingleton`,
   run `build_runner`, get auto-generated registration code. No manual `registerSingleton`
   calls.

5. **Testing is straightforward** — `getIt.reset()` clears all registrations,
   `getIt.registerSingleton<MyService>(MockService())` injects mocks.

6. **Riverpod is overkill** — GeoWake doesn't need reactive DI. State management is
   already handled via `ValueNotifier`, `StreamController`, and widget `setState`.
   Adding Riverpod would mean rewriting the entire state management layer.

### 2.4 Migration Plan

**Step 1: Add dependencies**

```yaml
# pubspec.yaml
dependencies:
  get_it: ^8.0.0

dev_dependencies:
  injectable_generator: ^2.6.0
  build_runner: ^2.4.0
```

**Step 2: Create service locator**

```dart
// lib/di/service_locator.dart
import 'package:get_it/get_it.dart';
import 'package:injectable/injectable.dart';

final getIt = GetIt.instance;

@InjectableInit()
Future<void> configureDependencies() async => await getIt.init();
```

**Step 3: Annotate services**

```dart
@lazySingleton
class MonetizationService {
  final PremiumService _premium;
  final PurchaseBackend _backend;

  MonetizationService(this._premium, this._backend);
}

@lazySingleton
class PremiumService {
  final PurchaseBackend _backend;
  PremiumService(this._backend);
}
```

**Step 4: Replace `.instance` calls**

```dart
// Before
final service = MonetizationService.instance;

// After
final service = getIt<MonetizationService>();
```

**Step 5: Initialize in main.dart**

```dart
void main() async {
  await Hive.initFlutter();
  await configureDependencies();  // replaces manual init calls
  runApp(GeoWakeApp());
}
```

**Step 6: Register interfaces, not concrete classes**

```dart
// Register abstract type → concrete implementation
@Register.as(AuthService)
@lazySingleton
class AuthServiceImpl implements AuthService { ... }
```

**Step 7: Testing**

```dart
setUp(() {
  getIt.reset();
  getIt.registerSingleton<ApiClient>(MockApiClient());
  getIt.registerSingleton<MonetizationService>(MockMonetizationService());
});
```

### 2.5 Background Isolate Considerations

The background isolate (`_onStart` in `trackingservice.dart`) needs its own `get_it`
registry. This is actually an advantage — the isolate can have a minimal set of
services without the full app registry:

```dart
@pragma('vm:entry-point')
void _onStart() {
  // Background isolate gets its own get_it instance
  final bgGetIt = GetIt.instance;
  bgGetIt.registerSingleton<NotificationService>(NotificationService());
  bgGetIt.registerSingleton<TrackingService>(TrackingService());
  // ... only what the isolate needs
}
```

### 2.6 Effort Estimate

- ~15 services to annotate and migrate
- ~50-100 call sites to update (`.instance` → `getIt<>()`)
- 1-2 days of focused work
- Can be done incrementally — migrate one service at a time
- No functional changes, purely structural

---

## 3. Backend Merge Engine: Persistent Storage Architecture

### 3.1 Current State

The merge engine (`geowake-server/src/utils/mergeEngine.js`) is:
- **In-memory only** — `Map` for OD cells, catchment cells, device IDs
- **Singleton** — one instance per server process
- **No persistence** — all data lost on restart
- **No multi-instance support** — can't scale horizontally
- **K-threshold = 100** (very high, needs 100 contributing devices per cell)
- **Epsilon = 0.44** (central DP, Laplace noise applied at merge time)

### 3.2 Research Findings

#### Academic State of the Art (2025)

- **OD matrix anonymization** is an active research area. Key approaches:
  - **k-anonymity** via generalization hierarchies (ATG algorithm — 27% more precise, 9x faster than alternatives)
  - **Local Differential Privacy (LDP)** — devices add noise before sending (GeoWake already does this)
  - **Central DP (CDP)** — server adds noise after aggregation (GeoWake does this too)
  - **Hybrid LDP + k-anon** — best of both: LDP for individual privacy, k-anon for aggregate suppression
- **Federated systems with LDP** are the emerging standard for mobility data
- **TimescaleDB** is the production-proven choice for time-series aggregate data:
  - 90%+ storage compression via hybrid row-columnar storage
  - Continuous aggregates pre-calculate rollups (hourly/daily totals)
  - Automatic data retention policies
  - Sub-second query latency at scale

#### Industry Architecture Pattern

The consensus architecture for high-throughput aggregate data:

```
Devices → API ingestion → Redis (buffer) → PostgreSQL/TimescaleDB (persistent) → API reads
                              ↓
                    Continuous aggregates
                    (pre-computed rollups)
```

- **Redis** — ephemeral buffer for high-throughput ingestion, OTP sessions, rate limiting
- **PostgreSQL** — persistent storage for user data, raw aggregate cells
- **TimescaleDB** (PostgreSQL extension) — time-series partitioning for OD matrices
- **Continuous aggregates** — pre-computed hourly/daily summaries for fast dashboard queries

### 3.3 Recommended Architecture for GeoWake

#### Option A: PostgreSQL + Redis (Recommended)

**Why:**
- GeoWake's backend is already Express.js on Railway
- Railway supports PostgreSQL as a managed add-on ($5/month)
- Redis available as managed add-on ($3/month)
- No new infrastructure to learn
- Sufficient for GeoWake's scale (thousands of devices, not millions)

**Schema:**

```sql
-- Raw OD cells (device contributions)
CREATE TABLE od_contributions (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  device_id     VARCHAR(64) NOT NULL,
  user_id       UUID REFERENCES users(id),  -- nullable until accounts exist
  origin_station VARCHAR(50) NOT NULL,
  dest_station   VARCHAR(50) NOT NULL,
  hour_bin       INT NOT NULL CHECK (hour_bin BETWEEN 0 AND 23),
  day_type       VARCHAR(10) NOT NULL,
  noisy_count    INT NOT NULL,  -- already DP-noised on device
  consent_given  BOOLEAN NOT NULL DEFAULT TRUE,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Index for merge queries
CREATE INDEX idx_od_merge ON od_contributions (origin_station, dest_station, hour_bin, day_type);
CREATE INDEX idx_od_device ON od_contributions (device_id);

-- Released OD matrix (pre-computed by merge job)
CREATE TABLE released_od_matrix (
  origin_station  VARCHAR(50) NOT NULL,
  dest_station    VARCHAR(50) NOT NULL,
  hour_bin        INT NOT NULL,
  day_type        VARCHAR(10) NOT NULL,
  noisy_count     INT NOT NULL,  -- server-side DP noise added
  contributing_users INT NOT NULL,
  released_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (origin_station, dest_station, hour_bin, day_type)
);

-- Catchment data
CREATE TABLE released_catchment (
  station_id      VARCHAR(50) NOT NULL,
  hour_bin        INT NOT NULL,
  day_type        VARCHAR(10) NOT NULL,
  noisy_count     INT NOT NULL,
  contributing_users INT NOT NULL,
  released_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (station_id, hour_bin, day_type)
);
```

**Merge job (runs periodically or on ingest):**

```javascript
async function runMergeJob() {
  // 1. Aggregate raw contributions by cell key
  const cells = await pool.query(`
    SELECT
      origin_station, dest_station, hour_bin, day_type,
      SUM(noisy_count) as total_count,
      COUNT(DISTINCT device_id) as device_count
    FROM od_contributions
    WHERE created_at > NOW() - INTERVAL '7 days'
    GROUP BY origin_station, dest_station, hour_bin, day_type
  `);

  // 2. Apply k-anonymity + central DP
  const released = cells.rows
    .filter(c => c.device_count >= K_THRESHOLD)
    .map(c => ({
      ...c,
      noisy_count: laplaceNoise(c.total_count, EPSILON),
    }));

  // 3. Upsert into released_od_matrix
  for (const cell of released) {
    await pool.query(`
      INSERT INTO released_od_matrix
        (origin_station, dest_station, hour_bin, day_type, noisy_count, contributing_users)
      VALUES ($1, $2, $3, $4, $5, $6)
      ON CONFLICT (origin_station, dest_station, hour_bin, day_type)
      DO UPDATE SET noisy_count = $5, contributing_users = $6, released_at = NOW()
    `, [cell.origin_station, cell.dest_station, cell.hour_bin,
        cell.day_type, cell.noisy_count, cell.device_count]);
  }
}
```

**Redis for:**
- OTP session storage (5-min TTL)
- Rate limiting (already using `express-rate-limit` with memory store — Redis store for multi-instance)
- Ingestion buffer (if high throughput needed)
- Dashboard query cache (cache `buildDashboardSummary()` result for 5 min)

#### Option B: TimescaleDB (Future Scale)

When GeoWake reaches 100K+ devices, upgrade to TimescaleDB:

```sql
-- Convert od_contributions to hypertable (time-partitioned)
CREATE TABLE od_contributions (
  -- same columns as above
) PARTITION BY RANGE (created_at);

SELECT create_hypertable('od_contributions', 'created_at',
  chunk_time_interval => INTERVAL '1 day');

-- Continuous aggregate for hourly demand
CREATE MATERIALIZED VIEW hourly_demand
WITH (timescaledb.continuous) AS
SELECT
  dest_station,
  hour_bin,
  day_type,
  SUM(noisy_count) as total_count,
  COUNT(DISTINCT device_id) as device_count
FROM od_contributions
GROUP BY dest_station, hour_bin, day_type, time_bucket('1 hour', created_at);
```

Benefits at scale:
- 90%+ storage compression
- Automatic partition pruning (queries only scan relevant time chunks)
- Continuous aggregates pre-compute dashboard queries
- Automatic data retention (drop partitions older than 90 days)

#### Option C: SQLite (Minimal)

If cost is critical and scale is low (<1000 devices):

```javascript
const Database = require('better-sqlite3');
const db = new Database('geowake.db');

db.exec(`
  CREATE TABLE IF NOT EXISTS od_contributions (
    id TEXT PRIMARY KEY,
    device_id TEXT NOT NULL,
    origin_station TEXT NOT NULL,
    dest_station TEXT NOT NULL,
    hour_bin INTEGER NOT NULL,
    day_type TEXT NOT NULL,
    noisy_count INTEGER NOT NULL,
    created_at TEXT NOT NULL
  );
`);
```

- Zero infrastructure cost
- Single-file persistence
- No multi-instance support
- Good enough for validation phase

### 3.4 Recommended Migration Path

```
Current (in-memory Map)
    ↓ Phase 1
SQLite (better-sqlite3) — zero cost, single file, persistent
    ↓ Phase 2
PostgreSQL + Redis — multi-instance, scalable, user accounts
    ↓ Phase 3
TimescaleDB — time-series optimized, continuous aggregates, 90% compression
```

**Phase 1 (SQLite):** 2-3 hours of work. Replace `Map` with `better-sqlite3`.
Data survives restarts. No new infrastructure.

**Phase 2 (PostgreSQL + Redis):** 1-2 days. Add `pg` package, create schema,
migrate merge job to SQL queries. Add Redis for OTP sessions and rate limiting.
Enables user accounts and horizontal scaling.

**Phase 3 (TimescaleDB):** 1 day. Convert tables to hypertables, add continuous
aggregates. Only needed at 100K+ device scale.

### 3.5 K-Threshold Adjustment

Current `K_THRESHOLD = 100` is very high — it means **no cell will be released until
100 distinct devices contribute to that exact O-D pair + hour + day type combination**.

For early-stage validation with few hundred users, consider:
- **K = 5** (standard k-anonymity, used by Apple, Google)
- **K = 10** (conservative, still useful with ~500 devices)
- **K = 100** (current — only viable at 10K+ active devices)

Recommendation: lower to `K = 5` for validation phase, increase as user base grows.

---

## Summary of Recommendations

| Area | Recommendation | Effort | Priority |
|------|---------------|--------|----------|
| Localization | ✅ Done — kept en, hi, bn, ta, te | Complete | — |
| User accounts | Phase 2 — Google Sign-In (free), link IAP to account | 2-3 days | Post-launch |
| DI framework | get_it + Injectable | 1-2 days | Medium |
| Merge engine Phase 1 | SQLite (better-sqlite3) | 2-3 hours | High |
| Merge engine Phase 2 | PostgreSQL + Redis | 1-2 days | When user accounts land |
| Merge engine Phase 3 | TimescaleDB | 1 day | At 100K+ scale |
| K-threshold | Lower from 100 → 5 | 1 line | High |
| Maps cost | Tiered caching + client-side + OSRM fallback | See §4 | Critical |

---

## 4. Maps API Cost Mitigation Strategy

### 4.1 The Problem

Google Maps API is GeoWake's **biggest scaling cost**. Every user action triggers
billable API calls through the backend proxy (`mapsController.js`):

| API Call | When It Fires | Free Tier | Cost Above Free Tier |
|----------|--------------|-----------|---------------------|
| Directions | Every alarm armed (route + ETA) | 10K/month | $5/1K (Directions API, legacy) |
| Autocomplete | Every keystroke in search box | 10K/month | $2.83/1K (Places API New) |
| Place Details | When user selects a search result | 10K/month | $5/1K (Essentials) |
| Geocoding | Convert place → coordinates | 10K/month | $5/1K |
| Nearby Search | Find transit stops near user | 5K/month | $32/1K (Pro — expensive!) |

**Current caching:** `NodeCache` (in-memory, per-instance) with 5-15 min TTLs.

**Cost projection at scale (worst case, no mitigation):**

| Users | Directions/mo | Autocomplete/mo | Place Details/mo | Est. Monthly Cost |
|-------|--------------|-----------------|-----------------|-------------------|
| 100 | ~3K | ~5K | ~500 | $0 (within free tier) |
| 1K | ~30K | ~50K | ~5K | ~$200-300 |
| 10K | ~300K | ~500K | ~50K | ~$2,500-4,000 |
| 100K | ~3M | ~5M | ~500K | ~$25,000-40,000 |

**This is unsustainable.** A free app with 10K users would lose $3K+/month on
Maps alone. Need creative free solutions.

### 4.2 Strategy: Tiered Cost Reduction

#### Tier 1: Aggressive Caching (Free, Do Now)

Current cache is in-memory `NodeCache` — lost on restart, not shared across
instances. Upgrading to **Redis cache** is the single highest-ROI change:

```
Current:  App → Backend → NodeCache (per-instance) → Google Maps API
                                    ↑ MISS = $$
Improved: App → Backend → Redis (shared, persistent) → Google Maps API
                                    ↑ MISS = $$ (but 80% fewer misses)
```

**Cache TTL strategy by API:**

| API | Current TTL | Recommended TTL | Rationale |
|-----|------------|----------------|-----------|
| Directions (transit) | 5 min | 1 hour | Transit routes don't change within an hour |
| Directions (driving) | 5 min | 15 min | Traffic changes, but route is mostly stable |
| Autocomplete | 10 min | 30 min | Same query from many users = cache win |
| Place Details | — | 24 hours | Place name/address rarely changes |
| Geocoding | 15 min | 7 days | Coordinates of a place never change |
| Nearby Search | — | 6 hours | Transit stops don't move |

**Expected impact:** 70-80% cache hit rate → 70-80% fewer billable API calls.

**Cost:** Redis on Railway ~$3/month. Saves hundreds at 1K users.

**Implementation:** Replace `NodeCache` with `ioredis` in `cache.js`. Same
interface, different backend. ~2 hours of work.

#### Tier 2: Client-Side Caching (Free, Do Now)

The Flutter app should cache API responses locally so repeated actions
(re-arming the same route, re-searching the same destination) don't hit the
server at all:

```dart
// lib/services/maps_cache.dart
class MapsCache {
  static final MapsCache _instance = MapsCache._();
  static MapsCache get instance => _instance;
  MapsCache._();

  final _box = Hive.box('maps_cache');

  Future<T?> get<T>(String key, {Duration maxAge = const Duration(hours: 1)}) {
    final entry = _box.get(key);
    if (entry == null) return null;
    final data = jsonDecode(entry);
    if (DateTime.now().difference(DateTime.parse(data['cachedAt'])) > maxAge) {
      return null; // stale
    }
    return data['payload'] as T;
  }

  Future<void> set<T>(String key, T payload) async {
    await _box.put(key, jsonEncode({
      'cachedAt': DateTime.now().toIso8601String(),
      'payload': payload,
    }));
  }
}
```

**Cache keys:**
- Directions: `dir:${originLat},${originLng}:${destLat},${destLng}:transit`
- Place details: `place:${placeId}`
- Geocoding: `geo:${lat},${lng}` (reverse) or `geo:${address}` (forward)

**Expected impact:** 30-50% of server calls eliminated entirely (user re-arms
same route, re-searches same destination, re-opens same place).

**Cost:** $0. Uses existing Hive setup.

#### Tier 3: Autocomplete Optimization (Free, Do Now)

Autocomplete is the **most expensive** API because it fires on every keystroke.
A user typing "Bandra Station" triggers 14+ API calls (B-a-n-d-r-a-...).

**Solutions:**

1. **Debounce on client** (already should be done — verify):
   ```dart
   // Only fire after user stops typing for 300ms
   Timer? _debounce;
   void onSearchChanged(String query) {
     _debounce?.cancel();
     _debounce = Timer(const Duration(milliseconds: 300), () {
       _performSearch(query);
     });
   }
   ```

2. **Session tokens** (Google Places API New — reduces cost):
   ```dart
   // Use a session token for the entire autocomplete session
   final sessionToken = const Uuid().v4();
   // Pass sessionToken with autocomplete calls
   // Google bundles autocomplete + place details into one session billing
   ```

3. **Pre-populate popular destinations** (zero API cost):
   - Metro stations, bus stops, popular landmarks — stored locally in app
   - User searches "Bandra" → app finds it in local DB → no API call
   - Only falls back to Google Autocomplete for unknown queries

4. **Recent searches cache** (zero API cost):
   - Store last 20 searches in Hive
   - Show recent searches before hitting the API
   - User picks a recent search → zero API cost

**Expected impact:** 60-80% reduction in autocomplete API calls.

#### Tier 4: Self-Hosted OSRM for Routing (Free, Phase 2)

The biggest single API cost is **Directions** — every alarm arm triggers a
directions call for route + ETA.

**OSRM (Open Source Routing Machine)** can replace Google Directions for
**driving routes** entirely free:

- Self-hosted on a VPS ($5-10/month)
- Uses OpenStreetMap data (free, open)
- India extract from Geofabrik (~500MB)
- Faster than Google API (no network round-trip to Google)
- No traffic data (OSRM doesn't have live traffic)

**Hybrid approach:**
```
User arms alarm
    │
    ├── Driving mode → OSRM (free, self-hosted)
    │                  ↑ covers 90%+ of use cases
    │
    ├── Transit mode → Google Directions (paid, but cached aggressively)
    │                   ↑ OSRM doesn't do transit
    │
    └── Walking/biking → OSRM (free, self-hosted)
```

**Cost comparison:**
- Google Directions at 10K users: ~$1,500/month (300K calls × $5/1K)
- OSRM VPS: ~$10/month
- **Savings: $1,490/month at 10K users**

**What OSRM can't replace:**
- Transit directions (buses, metro, trains) — need Google or other transit API
- Autocomplete — OSRM doesn't do place search
- Place details — OSRM doesn't have place metadata
- Live traffic — OSRM uses static speed data

**Implementation:** Add OSRM as a fallback/primary for driving routes in
`mapsController.js`. If OSRM is available and mode is driving, use it. Otherwise
fall through to Google.

```javascript
// In mapsController.js
async function getDirections(req, res) {
  const { origin, destination, mode } = req.query;

  // Use OSRM for driving/walking (free)
  if (mode === 'driving' || mode === 'walking') {
    try {
      const osrmRoute = await osrmClient.route(origin, destination, mode);
      if (osrmRoute) return res.json(osrmRoute);
    } catch (e) {
      // Fall through to Google
    }
  }

  // Use Google for transit (paid, but cached)
  return googleApiProxy(req, res, { /* ... */ });
}
```

#### Tier 5: Nominatim for Geocoding (Free, Phase 2)

Replace Google Geocoding with **Nominatim** (open-source, uses OSM data):

- Self-hosted or use public API (1 req/sec limit — fine with caching)
- Free, no API key
- Accuracy is good for India (OSM coverage is decent)

**Implementation:** Same pattern as OSRM — try Nominatim first, fall back to
Google if it fails or for high-precision needs.

### 4.3 What NOT to Replace

Keep Google Maps API for:

1. **Autocomplete** — Google's fuzzy matching is far superior to Nominatim.
   User experience depends on this. Cache aggressively instead.

2. **Transit directions** — No free alternative has India transit data.
   Google is the only option. Cache aggressively (1 hour TTL).

3. **Place details** — Google has the richest place metadata (photos, reviews,
   hours). Cache for 24 hours.

4. **Nearby search** — Used for finding transit stops. Cache for 6 hours.
   Could be replaced with a local database of transit stops (long-term).

### 4.4 Cost Projection With Mitigation

| Users | Without Mitigation | With Tiers 1-3 | With Tiers 1-4 |
|-------|-------------------|----------------|----------------|
| 100 | $0 | $0 | $0 |
| 1K | ~$250 | ~$50 | ~$15 |
| 10K | ~$3,000 | ~$600 | ~$100 |
| 100K | ~$35,000 | ~$7,000 | ~$1,200 |

**At 10K users with all tiers:** ~$100/month Maps cost + $10/month OSRM VPS =
**$110/month total.** Sustainable for a free app.

### 4.5 Revenue Offset

Even with aggressive cost reduction, Maps API costs grow with users. Revenue
sources to offset:

| Source | Revenue | Notes |
|--------|---------|-------|
| Pro purchases (₹199 one-time) | ~₹199/user | Even 5% conversion = ₹10/user avg |
| Rewarded ads (day pass) | ~₹2-5 per ad view | Google AdMob, non-intrusive |
| Aggregate data sales (future) | TBD | DP-protected OD matrices to transit agencies |

**At 10K users with 5% Pro conversion:** 500 × ₹199 = ₹99,500 (~$1,200)
Maps cost: ~$110/month. **Net positive.**

### 4.6 Implementation Priority

| Priority | Action | Effort | Impact |
|----------|--------|--------|--------|
| **P0** | Redis cache (replace NodeCache) | 2 hours | 70-80% fewer API calls |
| **P0** | Client-side Hive cache for maps | 3 hours | 30-50% fewer server calls |
| **P0** | Autocomplete debounce + session tokens | 1 hour | 60% fewer autocomplete calls |
| **P1** | Pre-populate metro stations locally | 4 hours | Eliminates nearby search for transit |
| **P1** | Recent searches cache | 2 hours | 20% fewer autocomplete calls |
| **P2** | Self-host OSRM for driving routes | 1 day | Eliminates driving directions cost |
| **P2** | Self-host Nominatim for geocoding | 4 hours | Eliminates geocoding cost |
| **P3** | Local transit stops database | 2 days | Eliminates nearby search entirely |
