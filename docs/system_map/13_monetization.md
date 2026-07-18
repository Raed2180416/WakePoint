## Monetization — Ads, Premium, Payment, Post-Arrival, Route Memory

**Role in the core promise:** The core promise is *reliability* — wake the rider before their stop, never late, never at the wrong place, even when GPS dies. Monetization's job is therefore mostly **negative**: it must earn money **without ever touching that reliability**. Every rule in this subsystem is bent around one guardrail — *no ad, no paywall, no upsell may compete with, delay, or obscure the wake alarm, and the alarm must work identically for a free user and a paying user*. Concretely: the alarm/wake/lock-screen surfaces are a hard ad denylist enforced by construction ([`ad_policy.dart:68`](../../lib/services/monetization/ad_policy.dart#L68)); the "always-free" reliability capabilities are pure getters that return `true` unconditionally ([`premium_service.dart:198`](../../lib/services/monetization/premium_service.dart#L198)); and the entire stack is *fail-open / degrade-to-free* — if the store is down, prefs are corrupt, or the ad SDK never initialises, the user is simply a free (never a broken) user and the alarm is untouched ([`monetization_service.dart:66`](../../lib/services/monetization/monetization_service.dart#L66)). Route Memory (saved routes) is bundled here because it is the "convenience" tier's foundation and an API-cost lever, though today it ships free.

**Files:**

| Path | What it does |
| --- | --- |
| `lib/services/monetization/ad_policy.dart` | Pure, stateless, I/O-free decision function: *may an ad appear at this surface right now?* Holds the hard denylist and the frequency-cap constant. Exhaustively unit-testable. |
| `lib/services/monetization/ad_service.dart` | Concrete `google_mobile_ads` adapter, gated by `AdPolicy` + `PremiumService`. Builds banners, interstitials, rewarded videos. Fail-open: any ad error is swallowed. |
| `lib/services/monetization/premium_service.dart` | The entitlement brain. Free vs Pro (one-time unlock) vs rewarded day-pass. Pure, dependency-injected (store backend + get/set persistence). Exposes every feature gate as a getter. |
| `lib/services/monetization/purchase_backend.dart` | Abstract billing seam + `FakePurchaseBackend` for tests. Keeps the SDK out of the pure logic. |
| `lib/services/monetization/purchase_backend_impl.dart` | Concrete `in_app_purchase` adapter. Fail-closed: Pro granted only on a real `purchased`/`restored` stream event. Handles late/pending UPI purchases. |
| `lib/services/monetization/monetization_service.dart` | App-level facade/singleton. Assembles PremiumService + real backend + SharedPreferences + ride counter. `init()` fired-and-forgotten at app start. |
| `lib/services/monetization/post_arrival_service.dart` | Model + builder for the flagship "last-mile intent" card. Pure, headless, PII-free by construction (throws if a coordinate/PII leaks in). |
| `lib/widgets/gated_banner_ad.dart` | Flutter banner widget that renders **nothing** unless a real ad loaded AND policy permits. Collapses to zero height for Pro / no-fill. |
| `lib/widgets/post_arrival_card.dart` | Flutter view for `PostArrivalCard` — primary CTA button + secondary chips + dismiss. |
| `lib/services/saved_route.dart` | `RouteMemory` immutable model — one automatically-remembered trip (coarse signature, counter, last origin). |
| `lib/services/saved_routes_service.dart` | `RouteMemoryService` — Hive-backed automatic memory of travelled routes (recents + pinned frequents), plus the "same origin ⇒ reuse cached route" helper. |

---

### How it works, step by step (the atomic walkthrough)

#### 1. App start — assembling the stack (fail-open)
- `main.dart:56` calls `unawaited(MonetizationService.instance.init())` — **fire-and-forget, off the critical path**. A slow store or ad SDK can never delay app startup, and the alarm never waits on it.
- `MonetizationService.init()` ([`monetization_service.dart:39`](../../lib/services/monetization/monetization_service.dart#L39)):
  1. Constructs `IapPurchaseBackend` and awaits `iap.init()` (which checks `InAppPurchase.isAvailable()` and, if available, subscribes to the long-lived `purchaseStream`).
  2. Builds `PremiumService`, injecting `SharedPreferences`-backed `load`/`save` closures keyed by string.
  3. Wires `_backend.onEntitlementChanged = (owned) => premium.applyOwnedProducts(owned)` — so an asynchronously-arriving purchase grants Pro.
  4. `await premium.load()` — reads the persisted entitlement blob.
  5. Reads `_ridesSinceLastAd` from prefs (`gw_rides_since_last_ad`, default 0).
  6. Sets `_ready = true`.
  7. `AdService.instance.init()` — *also* unawaited; ad SDK init is slow and non-essential.
  - **On ANY exception**, the `catch` at line 66 falls back to `FakePurchaseBackend()` + an in-memory `PremiumService`, still sets `_ready = true`. The user becomes a functioning free user; nothing throws into startup.

#### 2. The ad gate — three concentric checks
When any surface asks "show an ad here?", the decision flows: **`GatedBannerAd`/caller → `AdService._gate` → `AdPolicy.canShow`**.

`AdPolicy.canShow(placement, isPro, ridesSinceLastAd)` ([`ad_policy.dart:79`](../../lib/services/monetization/ad_policy.dart#L79)) evaluates in this exact order (fail-closed):
1. `if (isPro) return false;` — Pro removes every ad everywhere.
2. `if (alwaysForbiddenPlacements.contains(placement)) return false;` — `alarm`, `wake`, `lockScreen` are **never** monetized, for anyone. This is the reliability guardrail expressed as data.
3. `if (!adEligiblePlacements.contains(placement)) return false;` — anything not on the explicit allowlist (`routeArming`, `mapTracking`, `postArrival`) is denied. **Default-deny.**
4. `if (frequencyCappedPlacements.contains(placement)) return ridesSinceLastAd >= frequencyCapRides;` — only `postArrival` is capped, at `frequencyCapRides = 3` (MONETIZATION §1's "every 3 rides" floor).
5. Otherwise (`routeArming`, `mapTracking` banners) → `return true` — low-intrusion banners are uncapped for free users.

`AdService._gate` ([`ad_service.dart:144`](../../lib/services/monetization/ad_service.dart#L144)) adds two more prerequisites *before* delegating to the policy: `_initialized` must be true, and the platform must be Android/iOS. So the effective predicate is `initialized ∧ mobile ∧ policy.canShow(...)`.

#### 3. Banner rendering — the `GatedBannerAd` lifecycle
- On `initState` ([`gated_banner_ad.dart:29`](../../lib/widgets/gated_banner_ad.dart#L29)): reads `MonetizationService.instance.premiumOrNull`. If monetization isn't ready yet (`null`), it renders nothing and returns — **no crash on the late `premium`**.
- Calls `AdService.createBanner(placement, premium, size: AdSize.banner, onLoaded, onFailed)` ([`ad_service.dart:65`](../../lib/services/monetization/ad_service.dart#L65)):
  - `_gate(placement, premium, ridesSinceLastAd: 0)` — banners aren't frequency-capped, so 0 is fine.
  - If gate fails → returns `null` (Pro user, forbidden surface, uninitialised, desktop).
  - Else constructs a `BannerAd` with the current `_bannerUnitId`, attaches a listener (`onAdLoaded → onLoaded`, `onAdFailedToLoad → dispose + onFailed`), calls `ad.load()`, returns it.
- `build` ([`gated_banner_ad.dart:59`](../../lib/widgets/gated_banner_ad.dart#L59)): **`if (ad == null || !_loaded) return const SizedBox.shrink();`** — collapses to zero height until a *real* ad is confirmed loaded. This is the fix for the old bug where a fixed grey placeholder bar showed even to paying Pro users.
- Wired at two surfaces: **route-arming** (`homescreen.dart:1429`, as the `bottomNavigationBar`) and **above-ground map tracking** (`maptracking.dart:1081`). Both sit in a `SafeArea` `bottomNavigationBar`, so they never cover the map or the Wake-Me control, and the full-screen wake alarm supersedes the small banner anyway.

#### 4. Interstitial + rewarded (built, dormant — see Gaps)
- `AdService.maybeShowInterstitial(placement, premium, ridesSinceLastAd)` ([`ad_service.dart:96`](../../lib/services/monetization/ad_service.dart#L96)): gates, then `InterstitialAd.load(...)`; on `onAdLoaded` calls `ad.show()` and completes the `_Once<bool>` true; on fail completes false. Returns whether an ad was shown. Never throws.
- `AdService.showRewarded(premium, onReward)` ([`ad_service.dart:125`](../../lib/services/monetization/ad_service.dart#L125)): early-returns if already Pro; loads a `RewardedAd`; on load calls `ad.show(onUserEarnedReward: (_,__) => onReward())`. The `onReward` callback is where a caller would call `PremiumService.grantRewardedDayPass()` — **but no caller is wired** (see Gaps).
- `_Once<T>` ([`ad_service.dart:157`](../../lib/services/monetization/ad_service.dart#L157)) is a one-shot completer that ignores a second completion, because ad callbacks can race.

#### 5. Buying Pro — the fail-closed purchase path
- `PremiumService.buyPro()` ([`premium_service.dart:132`](../../lib/services/monetization/premium_service.dart#L132)): `await _backend.buyOneTime(proProductId)`; **only on `true`** sets `_proOwned = true` and persists. Never grants on decline.
- `IapPurchaseBackend.buyOneTime(productId)` ([`purchase_backend_impl.dart:80`](../../lib/services/monetization/purchase_backend_impl.dart#L80)):
  1. If store unavailable → `false`.
  2. `queryProductDetails({productId})`; if empty → `false`.
  3. Registers a `Completer<bool>` in `_pendingBuys[productId]`.
  4. `buyNonConsumable(...)`; if `started == false` → `false`.
  5. **Awaits the completer with a 5-minute timeout, `onTimeout: () => false`.** The result is decided by the *stream*, not the call.
- The stream handler `_onPurchases` ([`purchase_backend_impl.dart:52`](../../lib/services/monetization/purchase_backend_impl.dart#L52)):
  - `purchased`/`restored` → add to `_owned`, complete any pending buy `true`, **and fire `onEntitlementChanged` even if no buy is in flight** (the critical UPI/pending path — a purchase that clears minutes after `buyOneTime` already timed out still grants Pro).
  - `error`/`canceled` → complete pending buy `false`.
  - `pending` → do nothing (wait).
  - Always `completePurchase(p)` if `pendingCompletePurchase`, so the store finalises the transaction (no refund/retry loop).
- Late-arriving grant path: stream → `onEntitlementChanged(owned)` → `PremiumService.applyOwnedProducts(owned)` ([`premium_service.dart:145`](../../lib/services/monetization/premium_service.dart#L145)), which grants + persists Pro **only when newly owned** (idempotent, never revokes).
- Restore (reinstall/new device): `restorePurchases()` → `_backend.restore()` → re-grants Pro if `proProductId` is owned.

#### 6. Entitlement persistence — strict, fail-safe, fail-closed
- Encoding: a single string `"<0|1>;<dayPassExpiryMs>"` under key `geowake_entitlement_v1` — dart:core only, no `dart:convert` (`_persist`, [`premium_service.dart:120`](../../lib/services/monetization/premium_service.dart#L120)).
- Decoding `load()` ([`premium_service.dart:94`](../../lib/services/monetization/premium_service.dart#L94)): splits on `;`, requires **exactly 2 parts**, requires `proStr` to be exactly `'0'` or `'1'`, requires `expStr` to match `^-?\d+$` (no whitespace — `int.tryParse(' 100')` would otherwise resurrect Pro from a tampered `"1; 100"`). Any deviation → silently leaves the user on Free. Any exception → free. **Never grants the paid unlock from ambiguous state.**

#### 7. `isPro` — the single source of truth
`isPro = _proOwned || hasActiveDayPass` where `hasActiveDayPass = _nowMs() < _dayPassExpiryMs` ([`premium_service.dart:181`](../../lib/services/monetization/premium_service.dart#L181)). Everything (ads, feature gates, UI tier) reads this one getter. Day-passes *extend, never shorten* (`grantRewardedDayPass`, [`premium_service.dart:165`](../../lib/services/monetization/premium_service.dart#L165)).

#### 8. The ride counter (drives the interstitial cap)
- `MonetizationService.recordRide()` ([`monetization_service.dart:75`](../../lib/services/monetization/monetization_service.dart#L75)): `_ridesSinceLastAd++` and persist.
- `MonetizationService.markAdShown()` ([`monetization_service.dart:84`](../../lib/services/monetization/monetization_service.dart#L84)): reset to 0 and persist.
- **Neither is called anywhere in `lib/`** (see Gaps) — so the counter is stuck at 0 and the post-arrival cap can never be satisfied even if the interstitial path were wired.

#### 9. The post-arrival card — the flagship "intent" surface
- `PostArrivalService.shouldShow({alarmDismissed})` ([`post_arrival_service.dart:231`](../../lib/services/monetization/post_arrival_service.dart#L231)): returns `alarmDismissed` — the card **can never appear until the wake alarm is dismissed**. This is the hard gate protecting the alarm.
- `PostArrivalService.build({stationName, city, nearby})` ([`post_arrival_service.dart:243`](../../lib/services/monetization/post_arrival_service.dart#L243)):
  1. Always synthesises the **primary CTA** `"Book a ride from the station"` (`rideHailing`, `isPrimary: true`).
  2. Appends injected `nearby` options — but only `food`/`directions` kinds with non-empty labels; any injected `rideHailing` is dropped as a duplicate; unknown kinds ignored.
  3. Always appends a `dismiss` action last ("Not now") — the card is trivially escapable at a time-pressured just-off-the-train moment.
  4. Title = `"You've arrived at $station"` (or `"You've arrived"` if empty).
  5. **`card.validate()` runs at construction** — the privacy invariant is enforced *here*, so a coordinate/PII-looking input throws (`PostArrivalPrivacyError`) rather than shipping to the UI, the ad network, or the mobility-data pipeline.
- `PostArrivalCard.validate()` ([`post_arrival_service.dart:178`](../../lib/services/monetization/post_arrival_service.dart#L178)) scans `title`, `stationName`, `city`, and every action `label` against `_piiPatterns` ([`post_arrival_service.dart:145`](../../lib/services/monetization/post_arrival_service.dart#L145)):
  - coordinate pair `-?\d{1,3}\.\d{3,}\s*[,;]\s*...`
  - lone high-precision decimal `-?\d{1,3}\.\d{4,}`
  - coordinate field name `\b(lat|lng|latitude|longitude)\b`
  - email `...@....`
  - long digit run `\d{7,}` (phone/id).
  Unknown action kinds throw `ArgumentError`. The error message names only the *field* and *reason*, **never echoing the offending value** — so the guard itself can't leak the data it rejects.
- `PostArrivalCardWidget` ([`post_arrival_card.dart:16`](../../lib/widgets/post_arrival_card.dart#L16)): renders the primary action as a `FilledButton.icon`, secondaries as `OutlinedButton.icon` chips in a `Wrap`, each with a stable `Key('post_arrival_action_<kind>')`. `onAction(kind)` is handed the *kind* (never a coordinate) for the host to wire to the affiliate deep-link.
- **Neither the service nor the widget is referenced anywhere in `lib/`** (see Gaps) — the highest-leverage revenue surface is fully built, fully tested, and **not shown to any user**.

#### 10. Route Memory — automatic recents + frequent trips
- `RouteMemoryService.record(...)` ([`saved_routes_service.dart:132`](../../lib/services/saved_routes_service.dart#L132)) is called from `homescreen.dart:498` on **every arm** (via `_recordRouteMemory`, silent, never throws into the arm path). It:
  1. Builds a **coarse signature** `RouteMemory.buildSignature` = `"<lat.3dp>,<lng.3dp>|<road|metro>|<line>"` ([`saved_route.dart:79`](../../lib/services/saved_route.dart#L79)) — destination snapped to ~100 m, so slider nudges (3 stops → 4 stops) and GPS jitter collapse to ONE entry rather than forking duplicates.
  2. Upserts by signature: existing → `timesTravelled + 1`, refresh recency/config/origin; new → starts at 1.
  3. `_prune`: keeps every frequent trip (cap `maxFrequent = 12`) + the newest `maxRecents = 3` non-frequent trips.
- `isFrequent = timesTravelled >= frequentThreshold (3)` ([`saved_route.dart:74`](../../lib/services/saved_route.dart#L74)) — a trip armed 3× is pinned and survives the rolling recents window.
- `list()` ([`saved_routes_service.dart:98`](../../lib/services/saved_routes_service.dart#L98)) returns frequents (by count, then recency) then recents (by recency) — the home-screen render order.
- `isSameOrigin(r, lat, lng, tol=300m)` ([`saved_routes_service.dart:218`](../../lib/services/saved_routes_service.dart#L218)): haversine distance from the trip's `lastOrigin`; ≤ 300 m ⇒ the arming path may reuse a cached Directions result **without a new API call** (the cost lever). Returns false if no stored origin.
- Storage: one Hive `Box<String>` (`route_memory_v1`) holding the whole list as JSON, self-healing — if the box is corrupt it's deleted and recreated (`_ensureBoxIsOpen`, [`saved_routes_service.dart:39`](../../lib/services/saved_routes_service.dart#L39)). All reads swallow errors and return `[]`.

---

### Key types & functions

| Type / function | Responsibility & signature |
| --- | --- |
| `AdPlacement` (enum) | The surfaces an ad can be requested for: `routeArming`, `mapTracking`, `postArrival` (eligible) + `alarm`, `wake`, `lockScreen` (hard-denied). |
| `AdPolicy.canShow(AdPlacement, {bool isPro, int ridesSinceLastAd}) → bool` | Pure gate; the only place "may an ad show" is decided. |
| `AdPolicy.shouldOfferRewardedUnlock({bool isPro, bool dayPassActive}) → bool` | Whether to *offer* the opt-in rewarded day-pass (free + no active pass). |
| `AdService` (singleton) | `createBanner(...) → BannerAd?`, `maybeShowInterstitial(...) → Future<bool>`, `showRewarded({premium, onReward}) → Future<void>`, `configure({banner, interstitial, rewarded})`, `init()`. Fail-open adapter. |
| `PremiumService` | Entitlement brain. `buyPro()`, `applyOwnedProducts(Set)`, `restorePurchases()`, `grantRewardedDayPass({Duration})`, `load()`; getters `isPro`, `hasProOneTime`, `hasActiveDayPass`, `tier`, `canUseCoreAlarm`(≡true) … 13 premium gates. |
| `PremiumService.alwaysFreeCapabilities` | The set `{coreAlarm, basicReliability, singleActiveRoute, backstopAlarm}` that must never be gated. |
| `PurchaseBackend` (abstract) | Billing seam: `buyOneTime(id) → Future<bool>`, `restore() → Future<Set<String>>`, `onEntitlementChanged` callback. Keeps the SDK out of pure logic. |
| `IapPurchaseBackend` | `in_app_purchase` adapter; fail-closed; persistent `purchaseStream` listener for late/pending purchases. |
| `FakePurchaseBackend` | Deterministic in-memory backend for tests: `buyShouldSucceed`, `throwOnBuy`, `simulateLatePurchase(id)`. |
| `MonetizationService` (singleton) | Facade: `init({backendOverride})`, `recordRide()`, `markAdShown()`, `premium`, `premiumOrNull`, `ridesSinceLastAd`, `isReady`. |
| `PostArrivalService` | `shouldShow({alarmDismissed}) → bool`, `build({stationName, city, nearby}) → PostArrivalCard`. |
| `PostArrivalCard` / `PostArrivalAction` / `LastMileOption` | Immutable, PII-free card model + `validate()` + telemetry-safe `toMap()`. |
| `RouteMemoryService` | `record(...)`, `list()`, `frequent()`, `recents()`, `getBySignature()`, `remove(id)`, `clear()`, `isSameOrigin(...)`. Static, Hive-backed. |
| `RouteMemory` | Immutable travelled-trip model: `signature`, `timesTravelled`, `isFrequent`, `lastOrigin{Lat,Lng}`, `copyWith`, `toMap`/`fromMap`. |

---

### Design decisions (the WHY)

1. **The alarm surfaces are a hard, data-driven denylist, not a code convention.** *Decided:* `alarm`/`wake`/`lockScreen` live in `alwaysForbiddenPlacements` and `canShow` returns false for them before any other logic, for Pro and free alike. *Why:* the one thing that must never happen is an ad delaying or obscuring the alarm; encoding it as a `const Set` makes "we never monetize the alarm" an *exhaustively unit-testable property* rather than a promise each call site must remember. *Trades off:* zero revenue at the highest-attention moment (the wake) — deliberately forfeited. *Flaw:* the denylist only protects the *in-app* ad surfaces this policy governs; it cannot stop, say, a future notification-based promo added elsewhere. The guarantee is only as strong as "all ad requests route through `AdPolicy`."

2. **Default-deny (fail-closed) placement allowlist.** *Decided:* anything not explicitly in `adEligiblePlacements` is denied (`ad_policy.dart:89`). *Why:* if a new surface is added and someone forgets to classify it, the safe default is *no ad*, not *ad everywhere*. *Trades off:* a genuinely-safe new surface earns nothing until explicitly allowlisted — friction on the money side, safety on the trust side. Correct trade for a trust-critical app.

3. **Banners uncapped, only post-arrival interstitial frequency-capped.** *Decided:* `frequencyCappedPlacements = {postArrival}` at `frequencyCapRides = 3`. *Why:* small banners on arming/map are low-intrusion background furniture; a full-screen interstitial is intrusive, so it's rationed to "every 3 rides" (MONETIZATION §1). *Trades off:* banners at India eCPMs ($0.2–1.5) are "a rounding error until millions of MAU" (MONETIZATION §2A) — so this earns almost nothing while still spending a little trust. *Flaw:* the cap is moot today because the interstitial path is never invoked and the ride counter never increments (see Gaps #1).

4. **Prefer opt-in rewarded video over forced pre-roll.** *Decided:* `showRewarded` + `shouldOfferRewardedUnlock` + a temporary "premium for a day" pass, rather than a forced interstitial at arm/arrive. *Why:* both attention moments are time-pressured; a forced video there causes arm-abandonment and churn; rewarded self-selects the ad-tolerant, has higher eCPM ($4–12), and adds zero forced friction (MONETIZATION §1). *Trades off:* rewarded only earns from users who opt in — lower volume. *Flaw:* entirely dormant — nothing calls `showRewarded`, and no `onReward` handler calls `grantRewardedDayPass`, so the "premium for a day" product doesn't exist to users (Gaps #2).

5. **Pure `AdPolicy` separated from the `google_mobile_ads` `AdService`.** *Decided:* all "should we" logic is I/O-free and dependency-free; the SDK adapter only executes an already-approved decision. *Why:* the SDK can't run headless (no method channel on Linux/CI), so isolating the rules keeps them 100% unit-testable (36+21 edge-case tests). *Trades off:* a little indirection. *No significant flaw* — this is the right seam.

6. **Ads are fail-open; entitlement is fail-closed.** *Decided:* every ad error is swallowed and returns "no ad" (`ad_service.dart` try/catches, `_Once`), while a purchase is granted *only* on a confirmed store event. *Why:* an ad that fails must never block the app; an entitlement that's ambiguous must never hand out the paid unlock for free. Opposite failure directions because the *safe* outcome is opposite (no-ad vs no-grant). *Trades off:* a genuinely-successful purchase that never emits a stream event (SDK bug) leaves the user unpaid until restore — the price of fail-closed. Accepted.

7. **One-time non-consumable "Pro" as the lead SKU, not a subscription.** *Decided:* `proOneTime = 'geowake_pro_onetime'`; the backend only implements one-time + restore. *Why:* India strongly prefers one-time unlocks over recurring subs (MONETIZATION §B, HANDOFF §5). *Trades off:* worse LTV than a subscription; caps the premium line at "a nice line, not a rocket." Subs "can extend this interface without touching PremiumService" later. *Flaw:* no annual sub option is implemented even though §B suggests offering one for LTV.

8. **Persist entitlement as a 2-field plaintext string with a strict fail-closed parser.** *Decided:* `"<0|1>;<expiryMs>"` in SharedPreferences; decoder rejects anything not exactly matching. *Why:* keeps the store dependency-free and prevents a malformed/tampered blob (`"1; 100"`) from resurrecting Pro via lenient parsing. *Trades off:* readability of the blob. *Flaw (serious):* this is **client-side entitlement with no server/receipt verification** — a rooted device can simply write `"1;0"` to the pref and get Pro for free. The strict parser stops *accidental* resurrection, not *deliberate* piracy. For a ₹399 one-time unlock this is an accepted India-market risk, but it should be a conscious one.

9. **Late/pending purchase handling via a persistent stream listener.** *Decided:* `onEntitlementChanged` fires on `purchased`/`restored` *even with no buy in flight*, and `applyOwnedProducts` is idempotent. *Why:* UPI/netbanking (dominant in India) frequently clears *minutes after* `buyOneTime` already timed out; without this the user is charged but stuck on Free until a manual restore. *Trades off:* extra state (`_owned`, `_pendingBuys`) and a 5-minute buy timeout window. Strong, India-aware design.

10. **`applyOwnedProducts` only ever grants, never revokes.** *Decided:* Pro is added on ownership, never removed. *Why:* never strip a paying user mid-trip. *Trades off:* refunds/chargebacks never downgrade the client — a small revenue leak. Intentional; trust > leakage.

11. **Reliability capabilities are unconditional `true` getters + a documented set.** *Decided:* `canUseCoreAlarm`/`canUseBasicReliability`/`canUseBackstopAlarm`/`canUseSingleActiveRoute` return `true` regardless of entitlement; `alwaysFreeCapabilities` names them; `isAlwaysFree()` is a defensive check. *Why:* gating the alarm would break the trust the whole product — and the future data business — rests on (HANDOFF §5). *Trades off:* the free tier is genuinely, fully useful, so conversion pressure is low. Deliberate. *No flaw* — this is the core promise made executable.

12. **Post-arrival card is a headless, PII-free-by-construction model that validates at build.** *Decided:* no coordinates ever enter the model — only station *name*/zone + generic action *kinds*; `validate()` throws on any coordinate/PII pattern and runs inside `build()`. *Why:* the card feeds the UI, the ad network, *and* the k-anonymous mobility-data pipeline (HANDOFF §4) — a leaked coordinate there is a privacy breach, so the guard "fails loudly here instead of shipping." *Trades off:* the regex guard can *false-positive* (a legitimate name containing a 7+ digit run or a high-precision decimal would throw) — a small usability risk in exchange for a hard privacy floor. *Flaw:* the guard is only invoked because `build()` calls it; a caller that hand-constructs a `PostArrivalCard` and skips `validate()` bypasses it.

13. **Post-arrival gated strictly behind `alarmDismissed`.** *Decided:* `shouldShow` returns false until the alarm is dismissed. *Why:* the card must never compete with the alarm; the intent moment is *after* the rider is off the train. *Trades off:* "most users won't open a post-arrival summary" (MONETIZATION §1), so reach is limited by design. Correct: safety first.

14. **Ride-hailing is always the single primary CTA; injected options are secondary and sanitised.** *Decided:* `build` hard-codes the primary, drops duplicate ride-hailing, keeps only `food`/`directions` with non-empty labels, always appends `dismiss` last. *Why:* last-mile ride-hailing is both the highest-value CPA and the user's actual need (MONETIZATION §C, the 10–50× lever), so it's structurally guaranteed to be present and prominent; dismiss is always escapable. *Trades off:* rigidity — the primary can't be A/B'd to another kind without code change. *Flaw:* the whole surface is dormant (Gaps #3), so this leverage is currently unrealised.

15. **Route memory is automatic (learned), not manual Home/Work.** *Decided:* every arm calls `record`; identity is a coarse signature; frequents pin at 3 travels. *Why:* GeoWake is position-dependent — you board wherever you are, so a fixed pinned destination is the wrong model (matches the user's saved-routes memory note). *Why coarse signature:* nudging the slider or GPS jitter must bump the existing entry's counter, not fork a new route. *Trades off:* two genuinely different destinations within the same ~100 m cell + same mode/line **collapse into one entry** — a real correctness edge for dense areas. *Second lever:* `lastOrigin` + `isSameOrigin(300m)` lets the arm path reuse a cached Directions result to cut API cost.

16. **Bounded storage (recents 3, frequents 12).** *Decided:* `_prune` caps the box. *Why:* a user visiting hundreds of destinations can't grow the box unbounded. *Trades off:* an old frequent trip beyond 12 is evicted despite being "frequent." Reasonable bound.

17. **`GatedBannerAd` trusts the `null`/`!loaded` contract and collapses to zero height.** *Decided:* render `SizedBox.shrink()` unless a real ad confirmed loaded. *Why:* fixes the prior stub bug where a grey placeholder showed even to Pro users — which both looked broken and violated "Pro is ad-free." *Trades off:* momentary layout shift when an ad loads late. Minor, correct.

---

### Invariants
- **No ad on `alarm`/`wake`/`lockScreen`, ever, for anyone.** (`AdPolicy.canShow` step 2; `alwaysForbiddenPlacements`.)
- **`isPro ⇒ no ad anywhere.**` (`canShow` step 1; `AdService.showRewarded` early-return.)
- **Reliability getters return `true` unconditionally** — `canUseCoreAlarm` and the other `alwaysFreeCapabilities` never depend on entitlement.
- **Pro is granted only on a confirmed `purchased`/`restored` event** — never on timeout/error/cancel/decline (fail-closed).
- **Entitlement grants are monotonic within a session** (`applyOwnedProducts` never revokes; day-pass extends, never shortens).
- **A corrupt/malformed persisted blob ⇒ Free**, never Pro, never a thrown exception into startup.
- **The post-arrival model carries no coordinates and no PII** — `validate()` (run at `build`) guarantees it or throws before anything downstream sees it.
- **The post-arrival card never shows until `alarmDismissed == true`.**
- **`MonetizationService` degrades to a working free user on any init failure** (`_ready` still becomes true; core alarm unaffected).
- **Route memory identity is the coarse signature** — same signature updates in place (no duplicate entries).

---

### Interfaces

**Consumes:**
- `main.dart` → `MonetizationService.instance.init()` (fire-and-forget at startup).
- `SharedPreferences` (entitlement blob `geowake_entitlement_v1`, ride counter `gw_rides_since_last_ad`).
- `google_mobile_ads` SDK (via `AdService` only) and `in_app_purchase` SDK (via `IapPurchaseBackend` only) — no other module imports these.
- `hive_flutter` (via `RouteMemoryService` box `route_memory_v1`).
- `homescreen.dart` → `RouteMemoryService.record/list/remove` on arm; `GatedBannerAd(routeArming)` at line 1429.
- `maptracking.dart` → `GatedBannerAd(mapTracking)` at line 1081.

**Exposes (contracts other subsystems should use but mostly don't yet):**
- `MonetizationService.premium.isPro` / `.canUse*` — the entitlement gates the rest of the app should consult before offering premium features.
- `MonetizationService.recordRide()` / `markAdShown()` — the tracking/arrival flow *should* call these to drive the ad cap.
- `AdService.maybeShowInterstitial` / `showRewarded` — the arrival/settings flows *should* call these.
- `PostArrivalService.build/shouldShow` + `PostArrivalCardWidget` — the tracking/arrival flow *should* render this after alarm dismissal; `onAction(kind)` is the affiliate deep-link seam.
- `RouteMemoryService.isSameOrigin` + `RouteMemory.lastOrigin*` — the Directions/route-caching subsystem consumes these to decide whether to reuse a cached route (cost lever). **Note:** the actual cache-reuse decision lives in the arming/routing path, not here; this module only supplies the proximity signal.

---

### Gaps & flaws vs the core promise

The reliability guardrails in this subsystem are genuinely strong and well-tested (107+ monetization/route-memory test cases: `test/monetization/*`, `test/widgets/post_arrival_card_widget_test.dart`, `test/saved_routes_service_test.dart`). The subsystem does not threaten the core promise. **But as a *revenue* system it is mostly built-and-dormant** — the pure logic exists and is proven; the wiring into the live app flow largely does not.

1. **Interstitial cap is dead code end-to-end.** `MonetizationService.recordRide()` and `markAdShown()` are **never called anywhere in `lib/`** (verified by grep). So `_ridesSinceLastAd` is permanently 0, `canShow(postArrival)` is permanently false (`0 >= 3` is false), and `maybeShowInterstitial` is itself never invoked. The "every 3 rides" mechanism is fully inert. **Severity: high** (a whole revenue lever is disconnected), zero impact on the alarm.

2. **The rewarded "premium for a day" product does not exist to users.** `AdService.showRewarded`, `AdPolicy.shouldOfferRewardedUnlock`, and `PremiumService.grantRewardedDayPass` are all built and tested but **no caller wires them** — there is no UI to trigger a rewarded video and no `onReward → grantRewardedDayPass` handler. The design's *preferred* ad format (MONETIZATION §1) ships as unreachable code. **Severity: high**, no alarm impact.

3. **The flagship post-arrival "last-mile intent" card is never shown.** `PostArrivalService` and `PostArrivalCardWidget` are **referenced nowhere in `lib/`** outside their own files. MONETIZATION §C calls this "the single highest-leverage monetization for GeoWake" (10–50× a banner impression) — and it is currently invisible to every user. The model, validation, and widget are complete; only the render-after-alarm-dismissal integration and the affiliate deep-link wiring are missing. **Severity: high** (largest revenue opportunity unrealised), no alarm impact.

4. **There is no purchase UI — no user can actually buy Pro.** `PremiumService.buyPro()` and `restorePurchases()` are **never called from `lib/`**. The entire entitlement engine, store adapter, and late-purchase plumbing exist, but there is no "Upgrade to Pro" / "Restore purchases" screen to invoke them. The premium tier is therefore unreachable revenue, and — worse — a paying user on a new device has no in-app way to restore. **Severity: high**, no alarm impact.

5. **Real AdMob unit IDs are never supplied — the app ships Google TEST ad units.** `AdService.configure(...)` is **never called**, so `_bannerUnitId`/`_interstitialUnitId`/`_rewardedUnitId` keep Google's public *test* IDs. This earns $0 and, more importantly, **shipping test ad units in a production release violates AdMob policy** and can get the ad account suspended. The banners that *are* wired thus produce no revenue and a policy risk. **Severity: high** (compliance + zero revenue).

6. **`canUseSavedRoutes` (and other premium gates) are unenforced/misleading.** `PremiumService.canUseSavedRoutes => isPro`, but `homescreen.dart` calls `RouteMemoryService.list/record/remove` **with no `isPro` check** — recents/frequents are fully free (which MONETIZATION §B actually assumes: "Recents/frequency is already built"). The gate getter is aspirational, not wired. Most of the 13 premium `canUse*` getters (`canUseMultipleAlarms`, `canUseOfflineMaps`, `canUseAllCities`, …) have **no enforcement call sites** either. **Severity: medium** — the premium feature-split is defined but not policed, so even if purchase existed, buyers wouldn't get differentiated features.

7. **Client-side entitlement is trivially spoofable.** No server receipt validation (Design #8). A rooted device sets `geowake_entitlement_v1 = "1;0"` and gets permanent Pro free. Accepted India-market risk, but undocumented as a decision and a real revenue leak if the premium tier is ever meaningfully priced. **Severity: medium** (revenue), no alarm impact.

8. **Day-pass and (future) any time-based entitlement trust the device wall clock.** `hasActiveDayPass` uses `DateTime.now()`; a user can set the clock forward to expire nothing / backward to extend a pass. Minor for a rewarded freebie. **Severity: low.**

9. **Leaked resources in the interstitial/rewarded paths.** `maybeShowInterstitial` and `showRewarded` call `ad.show()` but set **no `FullScreenContentCallback`**, so the `InterstitialAd`/`RewardedAd` objects are never `dispose()`d and dismissal isn't observed. Dormant today, but a latent memory leak once wired. **Severity: low.**

10. **Route-memory signature collision + plaintext location storage.** (a) Two distinct destinations within the same ~100 m cell + same mode/line **merge into one remembered trip** (Design #15) — a re-arm could pre-fill the *wrong* nearby destination's config; the user still confirms the destination in the Wake-Me flow, so this doesn't by itself fire an alarm at the wrong place, but it's a correctness papercut. (b) `RouteMemory` stores **exact** `lat`/`lng`, `placeId`, and `lastOrigin` for the user's real commute in **cleartext Hive** on device — the user's home/sleep/commute pattern unencrypted at rest. Note the asymmetry: the post-arrival card has a rigorous PII guard, while the on-device route store (arguably more sensitive) has none. Local-only, so not a network exposure, but for "a safety app that knows where you sleep" it deserves a conscious decision (e.g. encrypted box). **Severity: medium** (privacy-at-rest), low correctness.

11. **The whole ad guarantee is only as strong as "all ad surfaces route through `AdPolicy`."** There is no structural enforcement (e.g. a lint) preventing a future contributor from instantiating a `BannerAd`/notification promo directly, bypassing the denylist. The guardrail is a convention backed by tests of the *policy*, not of *every call site*. **Severity: low** today (only two wired surfaces, both correct), rising as the app grows.

**Bottom line vs the core promise:** monetization is correctly *subordinated* to reliability — the alarm is never gated, ads are hard-banned from the wake path, everything fails toward "free but working," and privacy is protected on the one surface (post-arrival) that feeds the network/data pipeline. The gaps are almost entirely on the *making-money* side: the two banner placements are the only live monetization, and they ship with test ad IDs earning $0. The premium purchase flow, the rewarded day-pass, the interstitial cap, and the flagship post-arrival intent card are all built, unit-tested, and **not connected to the app** — so today GeoWake protects the trust required to monetize but does not yet actually monetize.
