# GeoWake — Premium Feature Set + Ads: Implementation-Ready Spec

> App name is **GeoWake** in every user-facing string — never "WakePoint" or "geowake2".
> Status: the monetization *logic* (PremiumService, AdPolicy, PostArrivalService, MonetizationService, AdService, GatedBannerAd, PurchaseBackend) is already built and largely headless. This spec wires it to surfaces and layers the agreed feature set on top — **without touching the arm → track → alarm reliability spine.**

---

## 0. The two invariants that govern everything

1. **CORE IS ALWAYS FREE.** The never-late alarm, full accuracy / underground reliability, the process-death backstop, and a single active route are gated by *nothing*. `canUseCoreAlarm`, `canUseBasicReliability`, `canUseBackstopAlarm`, `canUseSingleActiveRoute` are hard-coded `true` and must **never** be referenced by any gate call.
2. **BASIC SHARE IS ALWAYS FREE.** The share link / "I've arrived" share is the organic growth loop and carries **no entitlement check anywhere**, on either the AppBar or the post-arrival screen.

Every other convenience is Pro. Every Pro gate is a read of an existing `PremiumService` getter routed through one choke point (`ProGate.run`), so a single `grep "ProGate.run"` enumerates and audits every paywall.

---

# 1. Entitlement / Gate Architecture

## 1.1 The single choke point

`lib/widgets/monetization/pro_gate.dart` (new)

```dart
ProGate.run(
  BuildContext context, {
  required bool allowed,          // premium.<getter>
  required PaywallSource source,  // for highlight + analytics
  required VoidCallback onAllowed,
});
// allowed == true  -> onAllowed()
// allowed == false -> Navigator.pushNamed(context, '/paywall', arguments: source)
```

Supporting pieces in the same file:
- `enum PaywallSource { drawer, recurringAutoArm, guardian, multiAlarm, savedRoutes, customSound, smartSnooze, offline, widget, wearOs, tripStats, postArrival }`
- `ProBadge` — a small "PRO" pill `StatelessWidget` for locked `ListTile`s/buttons.

**Entitlement reads must be null-safe.** Read `MonetizationService.instance.premiumOrNull` and treat `null` (before init) as **not allowed → show paywall**. Never read `.premium` from a gated UI tap (throws `LateInitializationError` before init).

## 1.2 Fail-safe-to-FREE (verified against code)

- `PremiumService.load()` is fail-closed: corrupt/tampered `gw_entitlement_v1` blob → free.
- `MonetizationService.init()` catches all and falls back to a free in-memory premium.
- `GatedBannerAd` honors `isPro`/no-fill and collapses.
- Uncertainty (null, loading, expired day-pass, corrupt blob) always resolves to **free**, never to broken.

`isPro` == permanent unlock **OR** an active rewarded day-pass (`PremiumService.dayPassExpiryMs`).

## 1.3 Reactivity (additive, no DI framework)

Keep `PremiumService` pure. At the `MonetizationService` facade add:
```dart
final ValueNotifier<EntitlementTier> tierListenable;
```
Bump it inside facade wrappers around `buyPro` / `restorePurchases` / `grantRewardedDayPass` / `applyOwnedProducts`. UI (paywall, `ProBadge`, `GatedBannerAd`, drawer) wraps in `ValueListenableBuilder`, so a purchase or day-pass instantly hides ads + unlocks with no restart. **UI must call through the facade, never `PremiumService` directly.**

## 1.4 FREE / PRO matrix

| Capability | Tier | Gate getter | Surface |
|---|---|---|---|
| **Never-late core alarm** | **FREE (invariant)** | none (`canUseCoreAlarm` hard-true) | Home → Wake-Me → /mapTracking → alarm |
| **Full accuracy / underground reliability** | **FREE (invariant)** | none (`canUseBasicReliability`) | implicit, no UI |
| **Process-death backstop alarm** | **FREE (invariant)** | none (`canUseBackstopAlarm`) | OS exact-alarm / system tone |
| **Single active route** | **FREE (invariant)** | none (`canUseSingleActiveRoute`) | arming flow |
| **Basic share link + "I've arrived"** | **FREE (invariant)** | **none — never gated** | AppBar action + PostArrivalScreen |
| Default alarm sound + all 11 bundled ringtones + full safe escalation | FREE | none | /ringtones ("Alarm & Sound") |
| Recents + auto-frequent saved routes | FREE | none | Home "Recent trips" chips |
| 1 manual pinned route | FREE | `canUseSavedRoutes` (at 2nd pin) | /savedRoutes |
| Trip-stat recording + shareable stat card + headline count | FREE (growth loop) | none | stat card / post-arrival |
| Single-transfer journey | FREE | none | arming flow |
| Recurring auto-arm | **PRO** (lead) | `canUseRecurringAlarms` | /savedRoutes route-detail, /auto-arm |
| Guardian mode (auto-share + arrived push) | **PRO** (lead) | `canUseGuardianMode` (new) | /guardian |
| Multiple simultaneous alarms (multi-target) | **PRO** | `canUseMultipleAlarms` | Home "+ Add another stop" |
| Unlimited saved routes (pins) | **PRO** | `canUseSavedRoutes` | /savedRoutes |
| Custom / premium sounds + escalation profiles + strong vibration | **PRO** | `canUseCustomAlarmSounds` | /ringtones locked rows |
| Smart snooze ("to next stop") | **PRO** | `canUseSmartSnooze` (new) | live alarm notification |
| Offline all-cities pack | **PRO** | `canUseOfflineMaps` | /offlineMaps |
| Home-screen widget | **PRO** | `canUseWidget` | Settings |
| Wear OS | **PRO** | `canUseWearOs` | Settings |
| Trip-stats dashboard (streaks/patterns/favorites) | **PRO** | `canUseTripStatsDashboard` (new) | /tripStats |
| Ad-free | **PRO** | `isPro` (automatic) | AdPolicy / GatedBannerAd |
| Opt-in data sharing | separate, default-OFF | own key `gw_data_consent_v1` | /dataConsent |

New getters to add (each one line, additive, in the PREMIUM section): `canUseGuardianMode => isPro`, `canUseSmartSnooze => isPro`, `canUseTripStatsDashboard => isPro`. All others already exist.

---

# 2. UX / Navigation Map

## 2.1 New named routes (add to `lib/main.dart` `onGenerateRoute`; existing routes unchanged)

Existing: `/splash → SplashScreen`, `/ → HomeScreen` (hub), `/preloadMap`, `/mapTracking → MapTrackingScreen`.

| Route | Screen | Notes |
|---|---|---|
| `/onboarding` | `OnboardingScreen` | first-run only (`gw_onboarded_v1`), ends at `/`, **no paywall** |
| `/paywall` | `GeoWakePaywallScreen` | arg `PaywallSource`; the single upsell surface |
| `/postArrival` | `PostArrivalScreen` | pushed AFTER alarm dismissed; hosts existing card |
| `/dataConsent` | `DataSharingConsentScreen` | DPDP Rule-3 standalone notice, default-OFF |
| `/settings` | `SettingsScreen` | full page; drawer becomes a shortcut |
| `/savedRoutes` | `SavedRoutesScreen` | manage commutes; >1 pin is the gate |
| `/auto-arm`, `/guardian`, `/tripStats`, `/offlineMaps` | Pro detail hosts | IA slots defined; built in later waves |

None of these intercept the arm/track/alarm path — all additive, reached only from drawer/settings/gate-taps/post-dismiss.

## 2.2 Paywall — `lib/screens/monetization/paywall_screen.dart`

`StatefulWidget`, arg `PaywallSource`. Scrollable, trust-first order:
1. Hero: "GeoWake Pro — Your commute on autopilot."
2. **Trust strip (always, top): "Your never-late alarm is free forever. Pro adds convenience, not safety."**
3. Value list, **lead items first**: [Recurring auto-arm], [Guardian mode], then Multiple alarms, Unlimited saved routes, Custom & escalating alarm + smart snooze, Offline all-cities, Widget & Wear OS, Trip stats, Ad-free. The item matching `PaywallSource` is highlighted/scrolled-to.
4. Primary CTA: "Unlock forever — <localized price, fallback ₹199>" → `facade.buyPro()` → `PurchaseBackend.buyOneTime(geowake_pro_onetime)`. On success: `tierListenable` bumps, snackbar, pop.
5. Secondary CTA (only if `AdPolicy.shouldOfferRewardedUnlock`): "Watch a short video for a free day of Pro" → `AdService` rewarded → `facade.grantRewardedDayPass()`.
6. Footer: "Restore purchases", Terms + Privacy (`url_launcher`), day-pass countdown from `dayPassExpiryMs`.

New `PurchaseBackend.queryPrice(String productId) → Future<String?>` (localized `ProductDetails.price`), added to the abstract class + `IapPurchaseBackend` + `FakePurchaseBackend`. **Wrap in try/catch with the hardcoded ₹199 fallback** so store-metadata failure never blanks/crashes the CTA.

## 2.3 Post-arrival — `lib/screens/monetization/post_arrival_screen.dart`

Pushed **only** when `PostArrivalService.shouldShow(alarmDismissed:true)`. Never shown while the alarm rings. Order encodes priority:
- **A.** Header "You've arrived at <station>" (from PII-validated `PostArrivalCard.title`).
- **B. FREE SHARE ROW (first, prominent, never gated)** — "Share GeoWake" + "I've arrived" (`share_plus`, no entitlement check). The growth loop.
- **C.** `PostArrivalCardWidget` (existing, currently unmounted) fed `PostArrivalService.build(...)`; `onAction(kind)` → `url_launcher` deep-link to affiliate/partner. Primary CTA "Book a ride from the station" = last-mile intent card (the real per-user revenue lever).
- **D.** Optional rewarded upsell strip — dismissible, **never an interstitial**. Only if `AdPolicy.canShow(AdPlacement.postArrival, isPro, ridesSinceLastAd>=cap)` AND `shouldOfferRewardedUnlock`. Every-3-rides cap via `MonetizationService.recordRide()`. Pro users see none of D.

### Post-arrival trigger — the ONE code touch near the alarm (fail-safe)
In `maptracking.dart`'s END-TRACKING handler, **do not reorder existing teardown**:
```dart
await AlarmPlayer.stop();
await TrackingService().completeEndTracking(navigateHome: false);   // unchanged, unconditional
try {
  await MonetizationService.instance.recordRide();
  if (MonetizationService.instance.isReady &&
      PostArrivalService.shouldShow(alarmDismissed: true)) {
    final card = PostArrivalService.build(/* ... */);
    Navigator.pushReplacementNamed(context, '/postArrival', arguments: card);
    return;
  }
} catch (_) {}          // catches Exception AND Error (PostArrivalPrivacyError is an Error)
Navigator.pushReplacementNamed(context, '/');   // always falls back to home
```
Never `await` `recordRide()`/`build()` ahead of the alarm-stop or the service teardown. **Regression test:** force `PostArrivalService.build()` to throw; assert `completeEndTracking()` still ran and the app still lands on `/`.

## 2.4 Other screens
- `DataSharingConsentScreen` — DPDP Rule-3 notice + one default-OFF `SwitchListTile`, persisted to a **dedicated** key `gw_data_consent_v1` (never the entitlement blob), wired to **no egress**. Physically separate from every other consent.
- `OnboardingScreen` — 4 slides (value / permission rationale / first commute / trust promise), no paywall, sets `gw_onboarded_v1`.
- `SettingsScreen` + trimmed drawer — wire the dead `SettingsDrawer` "Go Premium" stub (`settingsdrawer.dart` ~line 77) → `/paywall` with `PaywallSource.drawer`; show "Pro active / 23h left" once unlocked. Pro rows carry `ProBadge` and go through `ProGate.run`.

New persistence keys: `gw_onboarded_v1` (bool), `gw_data_consent_v1` (bool, default false). Existing `gw_entitlement_v1` and `gw_rides_since_last_ad` untouched.

---

# 3. Per-Feature Implementation

Each section: Dart files/classes · gate point · packages · core-safety note · **reviewer risk + required fix** · tests.

## 3.1 Recurring Auto-Arm (Pro)

**A scheduling shell around the existing arm pipeline** — an exact-alarm fires a headless callback at (commute time − lead), posts a "tap to cancel" pre-arm notice, waits out a cancel window, then calls the *identical* `TrackingService.startTracking()` + `registerRouteFromDirections()` the manual Wake-Me button calls. Zero alarm/reachability logic changes — it only decides *when* to press the arm button.

**New files**
- `lib/services/scheduling/auto_arm_schedule.dart` — model: `id`, `routeSignature` (FK to `RouteMemory.signature`), `label`, `hour/minute`, `Set<int> weekdays`, `leadTime` (default 5m), `preArmWindow` (default 90s), `enabled`, `snoozedUntilEpochDay`, `alarmId` (stable 31-bit hash). Pure `DateTime? nextFireAfter(DateTime now)`.
- `lib/services/scheduling/auto_arm_service.dart` — singleton. Hive box `auto_arm_schedules_v1` (self-healing, copy `RouteMemoryService` boilerplate). CRUD → `_reconcileAlarms()` registers `AndroidAlarmManager.oneShotAt(instant, alarmId, autoArmCallback, exact:true, wakeup:true, allowWhileIdle:true, rescheduleOnReboot:true)` — **one-shot per occurrence** (weekday masks/holiday skips can't be a fixed period), the callback re-arms the next. `init()` from `main` (fail-open).
- `lib/services/scheduling/auto_arm_callback.dart` — `@pragma('vm:entry-point') autoArmCallback(int alarmId)`: own isolate, may run process-dead. Guards → pre-arm notice → cancel-window → `_armFromMemory` → `rescheduleNext`. `_armFromMemory` runs `ReliabilityPreflightRunner.run()` and **refuses to arm a dead channel** (posts "Couldn't auto-arm — tap to fix"). No-progress watchdog (default 12m) STOPS tracking (never fires) on holiday/WFH.
- `lib/services/scheduling/auto_arm_state_store.dart` — `SharedPreferences` pending/cancel/skip handshake.
- `lib/screens/auto_arm_screen.dart` — editor (time, weekday chips, lead stepper, enable, "Skip today"). Gate surface.

**Changes to existing files**
- `C1` `trackingservice.dart` — extract HomeScreen's directions fetch into public headless-safe `TrackingService.fetchDirectionsForArm({origin,destination,transit})`; HomeScreen also calls it (no behavior change). `startTracking`/`registerRouteFromDirections` unchanged.
- `C2` `notification_service.dart` — `showPreArmNotice`/`cancelPreArmNotice` on a **new low-importance channel `geowake_prearm_channel_v1`** (never the alarm/backstop channels). Add `CANCEL_AUTO_ARM` + `SKIP_TODAY` actions to `classifyAction`/`_handleNotificationAction`.
- `C3` `main.dart` — after `MonetizationService.init()`: `unawaited(AndroidAlarmManager.initialize()); unawaited(AutoArmService.instance.init());` (non-blocking, fail-open).

**Gate** (3 layers): UI lock → paywall; `AutoArmService.upsert()/setEnabled(true)` refuses with `AutoArmDenied` when `!canUseRecurringAlarms`; **fire-time re-check** in `autoArmCallback` silently no-ops if Pro lapsed.

**Packages:** `android_alarm_manager_plus: ^4.0.9` (the only package that runs exact, Doze-surviving, reboot-persisting headless Dart at a wall-clock instant — WorkManager's 15-min periodic minimum is unsuitable); `uuid: ^4.5.1` (stable ids, skip if transitive).

**Core-safety:** adds no alarm/reachability/wake logic — invokes the identical `startTracking()+registerRouteFromDirections()`, so the never-late cone/evaluator/backstop run bit-for-bit; cannot cause a false wake (only new fire-like action is *starting* tracking; watchdog only STOPS); reliability channels never reused; all new code fail-open/wrapped.

**⚠ Reviewer risk — active-session stomp.** `startTracking()` (`trackingservice.dart:236`) has **no `isActive()` guard** — it unconditionally `setActive(true)` and repoints the active route. If an auto-arm fires from the headless isolate while a manual never-late journey is already in progress, it flips state and redirects an in-flight CORE alarm → missed/wrong wake.
**Required fix:** first action in `autoArmCallback` after the entitlement re-check, AND re-checked after the cancel window closes:
```dart
if (await TrackingStateStore.isActive()) {
  notice('already tracking — auto-arm skipped');
  await AutoArmService.rescheduleNext(s);
  return;   // BEFORE any startTracking()/GPS
}
```
Defensively also make `startTracking()` refuse-when-active (no-op + log) so the "second arm no-ops" invariant is true in code. Emulator integration test MUST assert tracking actually went live from the headless isolate.

**Tests:** `nextFireAfter` masks/midnight/DST/skip; 3-layer gate; `_reconcileAlarms` idempotency; overlapping schedules no-op; callback guards (deleted/disabled/wrong-weekday/forgotten-route/lapsed-Pro each abort with zero `startTracking` calls); cancel handshake; grep-test asserting `startTracking`/`registerRouteFromDirections` carry no entitlement import.

## 3.2 Multiple Simultaneous Alarms (Pro) + Unlimited Saved Routes (Pro)

**The physics engine is already multi-target.** `Reachability.bound()` (`core/reachability/reachability.dart:476`) returns a position-domain upper bound `sMaxMeters` that takes **no target**; `reachesTarget()`/`effectiveProgress()` take the target as a param. A single bound ≥ true progress is ≥ true progress for every target → firing target T at `effectiveProgress ≥ T.meters` is late-proof for all targets at once. **`reachability.dart`, `ReachabilityTracker`, `AlarmEvaluator.evaluateCoinciding` stay byte-for-byte unchanged.** Multi-target = compute the shared bound once/tick, test each target.

Semantics: multiple wake TARGETS along the ONE active journey (you can only be on one train), e.g. wake 2 stops before an interchange AND at the destination — not N unrelated routes.

**New file** `lib/services/tracking/alarm_target.dart`:
- `class AlarmTarget { String id; String label; double targetMeters; LatLng? point; AlarmMode mode; double value; AlarmTargetKind kind; bool enabled; }` — `targetMeters` resolved at arm time by `SnapToRouteEngine.snap` (`snap_to_route.dart`).
- `enum AlarmTargetKind { destination, intermediate }` — invariant: exactly one destination (terminates tracking), zero-or-more intermediates (fire-and-continue).
- `class AlarmTargetSet` — `toJson/fromJson`, sorted by meters, validated single-destination; **free-tier factory truncates to the single destination target.**

**Pipeline extension (backward-compatible):**
1. `AlarmContext` (`alarm_controller.dart:71`) gains `List<AlarmTarget> targets` default `const []`; empty → synthesize one destination target from existing `destination/alarmMode/alarmValue` (every current caller/test unchanged).
2. `checkAndTriggerAlarm` (line 527): compute `reachBoundMeters` once (target-independent block 1388–1459 moves above the loop), then `for (t in effectiveTargets) _evaluateOneTarget(t, bound, ...)`. Intermediate targets pass an events/legs view whose `finalDestination = t.targetMeters`.
3. Destination-fired "suppress everything" rule (lines 1559–1567) applies ONLY to the destination target's own state (`t.kind == destination`). Intermediates fire once and don't end the session.
4. Same-tick double-fire: enqueue + stagger via the alarm poll timer OR combine into one notification; keep per-target cooldown.

**Arm/persistence:** `startTracking` gains optional `List<AlarmTarget>? extraTargets`; serialize to `params['alarmTargets']`; parse in `background_handlers.dart _handleStartTracking`; persist `AlarmTargetSet` in `TrackingStateStore` key `alarm_targets_v1` and rehydrate on OS-kill restore.

**Unlimited saved routes:** extend `RouteMemory` (`saved_route.dart`) with `final bool pinned` (default false, migration-safe `m['pinned'] == true`). `SavedRoutesService`: `setPinned`, `pinnedCount`; `_prune`/`list` keep ALL pinned + frequent + newest recents, ordered pinned→frequent→recents. **Entitlement cap enforced at the pin action (UI), store stays pure.** Free = 1 pin; Pro = unlimited. Keeps the automatic-first UX (recents/frequency, not manual Home/Work).

**Gate:** multi-alarm at the "+ Add another stop" UI action AND defensively in `AlarmTargetSet` factory (`canUseMultipleAlarms`); saved routes at the pin action (`canUseSavedRoutes` when `pinnedCount >= 1`). **The per-tick evaluation loop is deliberately NOT gated** — an expired day-pass mid-journey must not drop already-armed alarms. Read `premiumOrNull` (null → not allowed).

**Packages:** none required — `hive`, `shared_preferences`, `in_app_purchase`, `google_mobile_ads` already present. Optional `uuid ^4.x` (see fix below — **now required**).

**⚠ Reviewer risk — missed destination wake via id collision + fired-state re-keying (a real never-late break).** Natural-key ids `'<meters>|<mode>|<value>'` are not unique; an intermediate coinciding with the destination produces the same id, and re-keying the proven dedup by `'$routeKey#$targetId'` lets an intermediate firing write the destination's fired flag → trips the "destination already fired → suppress everything" net → silently suppressed real wake. Also `migrateAlarmState` (keyed by `routeKey`) drifts on candidate-route switch.
**Required fix:**
1. **Collision-free ids:** destination gets a reserved sentinel id `'__dest__'` no user target can take; intermediates get opaque `uuid` ids. Natural key stays for UI upsert/dedup only, never as fire-state key.
2. **Additive, not re-keyed:** leave `_destinationAlarmFiredByKey`/`_firedLegIdsByKey`/`markLegFired`/`destinationAlarmFiredForKey` byte-for-byte untouched (they keep serving the single destination target). Store intermediate fire-state in a **separate new map** keyed `(routeKey, intermediateTargetId)` the legacy path never reads. Keep the "destination fired → suppress" net evaluating only the untouched destination flag.
3. Extend `migrateAlarmState` to also carry the new intermediate map across a route switch.
4. **OS-kill restore:** the destination target must ALWAYS be reconstructable from legacy single-destination params even if the `alarm_targets_v1` blob is absent/corrupt; null/loading entitlement fails-safe to FREE (drop *extra* targets, never the destination). An intermediate "alight" stop consuming a stop-request must NOT tear down tracking (per-target guard on the poll-timer stop consumer).

**Tests:** extend the b2eec7a 15-route at-scale never-late gate — arm 2–3 targets/route, assert 0 late/missed for every target, plus an explicit collision case (intermediate at exactly route-length with destination mode/value) asserting the destination still wakes; per-target dedup; same-tick double fire surfaces both; OS-kill restore; empty-targets byte-identical regression; `pinned` survives eviction / defaults false; free blocked at 2nd pin & 2nd alarm.

## 3.3 Guardian / Share (Share = FREE viral; Guardian = Pro)

Client-first, backend-pluggable. A new self-contained `lib/services/share/` package that only READS existing tracking streams.

**New files**
- `journey_share_models.dart` — `ShareMode {basicLink, live, guardian}`, `ShareStatus {enRoute, arrived, revoked, expired}`, `ShareSession`, `ShareSnapshot` (latest coarse position only — **no history/trajectory array**, enforced by test), `GuardianContact`.
- `share_link_builder.dart` — pure, no I/O. `buildShareUrl` (App-Links domain), `buildBasicMessage` (`'Track my journey — arriving ~hh:mm · GeoWake\n<url>'`), HMAC `mintToken/verify` (`crypto`, secret in `gw_share_secret`), `buildInstallFallbackUrl` (Play referrer so a recipient without the app still converts).
- `live_share_backend.dart` — `abstract LiveShareBackend {createSession, ping, markArrived, revoke, supportsLive}`. **`NoopLiveShareBackend` (default, `supportsLive=false`)** makes basic share work fully offline with a client-generated id. `HttpLiveShareBackend` skeleton maps to a documented `/v1/share` contract (server stores only latest snapshot, TTL then hard-delete, never routes into the data pipeline). Backend contract → `docs/share/BACKEND_CONTRACT.md`.
- `journey_share_service.dart` (FREE core) — singleton, Hive box `gw_share_sessions`. `startBasicShare` (no premium read — test-enforced), `bindTracking` (throttled ~15s `ping` matching `EtaEngine._saveThrottle`, lat/lng rounded to 5 dp, ephemeral, never aggregated), `revoke/revokeAll`, auto-expiry, `ValueNotifier<bool> isSharing`.
- `guardian_service.dart` (Pro) — Hive boxes `gw_guardian_contacts`, `gw_guardian_enabled` (**default false, opt-in**). Every mutating call first checks `canUseGuardianMode`. `bindAutoArm` auto-shares on arm (when Pro && enabled) and sends "arrived safely" on the alarm fire.
- UI: `lib/widgets/share/share_sheet.dart`, `lib/screens/guardian_setup_screen.dart`, `lib/widgets/share/guardian_settings_section.dart`.

**FREE share entry points (3):** `maptracking.dart` app-bar "Share journey"; `homescreen.dart` active-trip card; `post_arrival_card.dart` new `shareArrival` action kind. Persistent "You're sharing" banner in `maptracking.dart` bound to `isSharing`, tap to revoke.

**Gate:** add `bool get canUseGuardianMode => isPro;`. Checked in `GuardianService` (every mutating call), the setup-screen toggle (locked + `ProBadge` → paywall source `guardian`), and `bindAutoArm`. **Basic share makes NO premium read (test-enforced).**

**Packages:** add `share_plus (^10.x)`, `app_links (^6.x)` (inbound App Links / `geowake://`; replaces deprecated `uni_links` and the shut-down Firebase Dynamic Links), `url_launcher (^6.x)` (WhatsApp `wa.me` / `sms:`), optional `qr_flutter (^4.x)`. Reuses `crypto`, `http`, `web_socket_channel`, `hive`, `shared_preferences`.

**⚠ Reviewer risk — SILENT MISSED WAKE (design is `safe:false` as written).** `AlarmController.onDestinationAlarmFired` (`alarm_controller.dart:147`) is a **single unguarded callback invoked synchronously inside `setDestinationAlarmFiredForKey` (line 163) BEFORE `triggerAlarmNotification`** on every fire path (359, 720, 792, 1064, 1168, 1219, 1677, 1748), at a point where the fired-flag is already latched true. The design's claim "listeners fire after the alarm" is FALSE. A GuardianService listener that throws synchronously (un-opened Hive box, null contact, JSON error, async that throws before its first await) propagates out before the wake dispatches → the alarm never fires and never re-fires for that key. The codebase already flags this at lines 368–377 ("FINDING 6: a throw here would leave a permanent silent no-wake").
**Required fix:** do NOT reuse `onDestinationAlarmFired`.
1. Add a **separate `addPostAlarmListener` multicast invoked from the END of `triggerAlarmNotification`**, after the notification is dispatched — never from inside `setDestinationAlarmFiredForKey`.
2. Wrap EACH listener in its own try/catch and dispatch off the critical path (`scheduleMicrotask` / `unawaited(Future(() => l()))`) so a synchronous throw OR a hang in a guardian push can't delay/abort the ring.
3. Keep the existing single `onDestinationAlarmFired` (route-switch blocking) untouched.
4. **Load-bearing test:** a throwing AND a hanging post-alarm listener neither prevents the wake nor blocks other listeners.

**Core-safety (with fix):** read-only consumer of `ActiveRouteManager.stateStream`/`EtaEngine`; basic share never gated; no ad surface added; `ping` throttled 15s off the alarm thread, fails silently; `guardianEnabled` default false; snapshot carries only latest coarse position.

**External:** live backend (`/v1/share`), App-Links domain + `/.well-known/assetlinks.json` + recipient web page, FCM (arrived push) + optional DLT-registered SMS, Play referrer — **all optional for client-first ship** (Noop backend covers basic share).

**Tests:** message/URL format exact ("GeoWake" literal, PII-free); token round-trip + tamper-fail; `startBasicShare` offline; 15s throttle; revoke/expiry; snapshot has no trajectory field; free user can't enable Guardian; Pro auto-shares; arrived fires exactly once; multicast throw/hang safety; deep-link parse.

## 3.4 Custom / Escalating Alarm + Smart Snooze (Pro)

Default escalation (volume ramp G9b, native haptics G25) and all 11 bundled ringtones **stay FREE and are the enforced floor**. Pro is additive: premium sound pack + pick-your-own file, escalation *profiles*, strong vibration, and "snooze to next stop" bounded by the never-late deadline.

**New files**
- `lib/services/alarm/alarm_sound_profile.dart` — pure. `sealed AlarmSoundSpec {DefaultSound, BundledSound(assetPath), CustomSound(appLocalPath)}`; `enum EscalationProfile {standard, gentleLong, instantMax}` (`standard` == current constants **verbatim**); `enum VibrationIntensity {standard, strong}`; `AlarmSoundProfile.freeSafeFloor()`; `toJson/fromJson` (corrupt → floor). `ResolvedRamp` — `standard` = start 0.25 / end 1.0 / 12 steps / 400ms (identical to `AlarmPlayer` constants). **CLAMP: endVolume always 1.0 and steps*interval ≤ MAX_RAMP_DURATION (~8s)** so no profile can be quieter-at-end or slower than free.
- `lib/services/alarm/alarm_profile_store.dart` — **THE GATE.** `resolveEffective(PremiumService)`: if `!canUseCustomAlarmSounds` → force default/bundled from existing `selected_ringtone` pref + standard escalation/vibration; PRO → pass through but re-validate `CustomSound` path exists (else fall back to bundled/default — never silent). Blob key `gw_alarm_profile_v1`; free bundled selection stays in `selected_ringtone` so `RingtonesScreen` is untouched.
- `lib/services/alarm/custom_sound_manager.dart` — `file_picker` (SAF audio) → COPY bytes into `getApplicationSupportDirectory()/custom_sounds/<uuid>` (must survive process death / SAF grant revocation). Validate ≤5MB, ext ∈ {ogg,mp3,m4a,wav}, decode probe; reject undecodable/zero-length.
- `lib/services/alarm/smart_snooze_controller.dart` — **NEVER-LATE SAFETY.** Pure `SnoozeDecision decide()`: candidate refire = the "next stop" trigger instant; HARD CLAMP `refire ≤ deadline − SAFETY_MARGIN`; MIN `refire ≥ now + 20s`; if window empty → `allowed=false` (button hidden, alarm keeps ringing).
- `lib/screens/alarm_customization_screen.dart` — extends `RingtonesScreen`: keep free list + "Test my alarm now" FAB exactly; add locked Pro rows (premium pack, use-your-own, escalation style, vibration).

**Changes**
- `alarm_player.dart` — static injectable `AlarmSoundProfile Function()? effectiveProfileResolver` default null (null = identical to today). `playSelected` picks `AssetSource` (bundled/default) or `DeviceFileSource` (custom, audioplayers 6.x), wrapped in try/catch **falling back to the default asset on any failure**. Ramp constants come from `ResolvedRamp` when a profile is present else existing constants. AudioContext (usage:alarm, gainTransient, stayAwake), G8 route re-assertion, loop mode UNTOUCHED.
- `notification_service.dart` — `showWakeUpAlarm({bool allowSnooze=false})` prepends `SNOOZE_ALARM` action only when `premium.canUseSmartSnooze && decide().allowed`. Snooze handler: stop audio/vibration/notification via `cancelAlarm(restoreJourney:true)` (tracking CONTINUES) → `scheduleEtaBackstop(fireAt: decision.refireAt)` (OS exact-alarm surviving Doze/kill). Persist `pending_alarm_snooze` for resurrection fidelity. Channel/insistent flags [4,32]/fullScreenIntent unchanged.
- `premium_service.dart` — add `bool get canUseSmartSnooze => isPro;` (`canUseCustomAlarmSounds` already exists).

**Gate:** `AlarmProfileStore.resolveEffective` (downgrades to `freeSafeFloor` on not-Pro / null / expired / corrupt). Smart-snooze: `canUseSmartSnooze && decide().allowed` at the `showWakeUpAlarm(allowSnooze:)` call site. Backstop channel `geowake_backstop_channel_v1` keeps the OS system tone regardless of Pro.

**Packages:** `file_picker (^8.x)` (SAF, no new runtime permission); reuse `audioplayers ^6.4.0` (`DeviceFileSource`), `path_provider`, `shared_preferences`.

**⚠ Reviewer risk — the smart-snooze deadline input does not exist.** The design assumes `neverLateDeadlineMs` = "latest safe fire instant already computed by the pipeline." It doesn't: reachability produces only an instantaneous position upper bound (fire-NOW trigger) and the ETA backstop is deliberately an EARLY fire time. An implementer will most plausibly wire `decide()` to a smoothed/expected ETA — the wrong quantity and wrong direction (expected arrival can be LATER than worst-case), so clamping to expected − margin can schedule the re-fire AFTER the train reaches the stop → LATE / missed.
**Required fix:** `SmartSnoozeController` must **derive its own deadline by inverting the same worst-case `Reachability.bound` math** — solve for wall-clock t at which `anchor.sHi + V_LINE·(t − t_anchor)` (tightened by the same topology/dwell cap) first reaches `(target_progress − wakeLead)` — fed the LIVE `ReachabilityAnchor` and `V_LINE` from the tracking isolate (the objects `alarm_evaluator.dart` already consumes), never a smoothed ETA. REFUSE (`allowed=false`) whenever the worst-case deadline is unavailable/unprovable (no finite anchor, watchdog tripped, unknown/zero V_LINE, empty window). Fail-safe toward "keep ringing," never toward a late re-fire. Test asserts the deadline is the reachability inversion and a fast-but-within-V_LINE train never yields a refire past the true worst-case stop instant.
**Secondary:** since the resolver is wired app-wide in `MonetizationService.init()` for all users, add a mandatory equality test `ResolvedRamp(standard) == current _ramp* constants`, and a try/catch in `playSelected` that falls back to the current ramp constants if resolution throws.

**Tests:** JSON round-trip → floor; downgrade strips custom/non-standard; endVolume clamp==1.0 for every profile; missing custom file → fallback; `decide` refire < deadline−margin, refuses on empty window, refire ≥ now+MIN; `classifyAction('SNOOZE_ALARM')`; `allowSnooze:false` == current action set (regression); custom source uses `DeviceFileSource`, throwing source falls back to default asset; oversized/undecodable rejected; whole existing alarm suite green with `effectiveProfileResolver==null`.

## 3.5 Trip Stats — FREE shareable card + FREE recording; Pro dashboard

Local-only Hive ledger, one PII-free record per completed trip (fire-and-forget, off the alarm path). **Recording is unconditional/always-free** (upgraders keep history, share loop works for everyone); only the rich dashboard is gated.

**New files**
- `lib/services/stats/trip_record.dart` — immutable, PII-free (names + coarse buckets, never lat/lng): `completedAtMs`, `destStation?`, `line?`, `city?`, `mode`, `outcome` (`AlarmOutcome.name`), `hourOfDay`, `weekday`, `wokenOnTime`. `TripRecord.validate()` reuses `PostArrivalCard` PII regexes → factor into shared `lib/services/privacy/pii_guard.dart`.
- `lib/services/stats/trip_stats_service.dart` — box `geowake_trip_stats_v1`, one `records` `List<Map>` ring capped 2000 (copy `RecentLocationsService` self-healing lifecycle, every method try/catch → safe default). `recordTrip` (never throws), `allTrips`, `summary`, `lifetimeWokenOnTime`, `clear`. **No sink/http import.** Comment: "LOCAL ONLY, never transmitted, NOT the DATA_STRATEGY pipeline; only egress is a user-initiated share IMAGE."
- `lib/services/stats/trip_stats_summary.dart` — pure, injected `now`: streaks, month/lifetime counts, 24-bucket histogram, top-5 lines, distinct stations.
- `lib/widgets/stats/share_stat_card.dart` — FREE viral render target, fixed 1080×1350, branded, **non-removable "made with GeoWake" footer**. Default template STATION-FREE ("GeoWake woke me for my stop 47 times this month").
- `lib/services/stats/stat_card_exporter.dart` — `RepaintBoundary → toImage → PNG → path_provider temp → share_plus`. User-initiated only.
- `lib/screens/stats/trip_stats_screen.dart` — Pro dashboard; "Share my stats" + headline count ALWAYS free/live; detailed panels blurred behind `_TripStatsPaywall` when `!isPro`.

**Changes**
- `premium_service.dart` — `bool get canUseTripStatsDashboard => isPro;` (comment: recording + card are free/viral).
- `alarm_controller.dart` (~458–475) — immediately AFTER the existing `TelemetryService.instance.alarmOutcome(...)` block, add a second independent swallowed non-awaited block: `try { unawaited(TripStatsService.instance.recordTrip(TripRecord(...))); } catch(_){}`. Reuse the already-computed `mode`; nulls if station unavailable.
- `settingsdrawer.dart` — "My stats" tile + "Reset my stats" (`clear()` behind confirm).
- `post_arrival_card.dart` — milestone nudge (5/10/25/50/100 + monthly), strictly below `PostArrivalService.shouldShow`.

**Gate:** `canUseTripStatsDashboard` checked ONLY in `trip_stats_screen.dart` to blur panels. Recording + share card + headline count are FREE.

**Packages:** `share_plus (^10.1.x)`; reuse `path_provider ^2.1.1`, `hive`/`hive_flutter`, `google_fonts ^8.1.0`. `RepaintBoundary + dart:ui.toImage` are native — no screenshot package.

**⚠ Reviewer risk — cross/background-isolate Hive write.** The alarm most often fires in the BACKGROUND isolate (app swiped away; `alarm_controller.dart:487`), but `Hive.initFlutter()` is called ONLY in the UI isolate (`main.dart:51`). So the inline `recordTrip` throws "not initialized," gets swallowed, and trips systematically UNDERCOUNT (often to zero) — gutting the growth loop. "Fixing" it by init-ing Hive in the background isolate opens the SAME box from two isolates → corruption race (Hive is not multi-isolate-safe). The "identical to RecentLocationsService" claim is false — that pattern was only ever UI-isolate-only.
**Required fix:** enforce SINGLE-WRITER — never `openBox` from the background isolate. At fire, detect `isBackgroundIsolate` (the controller already has the flag) and hand the PII-free record to the UI isolate via the existing bridge — `service.invoke('recordTripStat', map)` (see `trackingservice.dart:1314/2440`) OR an append-only pending file mirroring `pending_ack_manager.dart`. UI isolate drains into the ledger on next foreground/resume (piggyback the `AppLifecycleState.paused/resume` flush in `main.dart:116–126`). When `isBackgroundIsolate == false`, write inline. Keep `recordTrip` double-swallowed and non-awaited.
**Secondary:** `toImage(pixelRatio:3.0)` on a 1080×1350 card renders ~13MP/~52MB RGBA — OOM-prone on budget India devices. Lower to `pixelRatio:2.0` (and/or 540×675 logical) and wrap `toImage`/`toByteData` in try/catch returning a `failed` enum.

**Core-safety:** write runs only after the fire decision and after `alarmOutcome` is emitted, `unawaited` inside its own try/catch; stats box independent of every core box; only egress is a user-initiated image (default station-free).

**Tests:** streak math (tz boundary, longest≥current); ring cap; corruption recovery returns empty; `clear`; `validate` rejects coordinates; gate false on free / true on pro+day-pass; a throwing fake `TripStatsService` proves the wake still completes; **background-isolate fire enqueues exactly one record and completes the wake even if the sink throws**; `ShareStatCard` goldens; non-empty PNG bytes.

## 3.6 Home Widget + Wear OS (Pro)

Two independently-shippable Pro surfaces (both gates already exist: `canUseWidget`, `canUseWearOs`).

**A — Home-screen widget (~4–5 days, client-only, do first).** Package `home_widget: ^0.7.0`, App Widget in the existing `:app` module (`com.example.geowake2`). New Dart:
- `lib/services/widget/home_widget_bridge.dart` — writes one JSON blob under `gw_widget_state_v1`, calls `HomeWidget.updateWidget`. `refresh()`: `!canUseWidget → pushLocked()` (upsell card) else `isActive() → pushActive()` else `pushIdle()` (top frequent route as arm candidate). All calls try/catch + fire-and-forget — a widget write must never throw into a caller.
- `lib/services/widget/widget_arm_handler.dart` — `@pragma('vm:entry-point')` interactivity callback parsing `homeWidget://arm?routeId=` / `stop`. Pure `WidgetArmDecision.evaluate({permsGranted, hasCachedRouteForOrigin, preflightBlockLevel}) → WidgetArmMode {headless, launchApp}`. **"One-tap" = headless fast-path ONLY when provably safe** (cached route + same origin + perms + preflight OK via `ReliabilityPreflightRunner`); otherwise deep-link `/quickArm?routeId=` into the normal foreground arm flow — **never silently arm a dead alarm.**

Android: `kotlin/com/example/geowake2/GeoWakeWidgetProvider.kt` (AppWidgetProvider), `res/layout/geowake_widget.xml`, `res/xml/geowake_widget_info.xml`, manifest `<receiver>` registration. **Per the "backstop receivers gotcha," verify the receiver actually appears in the merged manifest and declare manually if the merge drops it.**

Wiring (all `unawaited`, additive): `main.dart` init; `startTracking`/`stopTracking` end; `TrackingStateStore.saveProgressPayload` (throttled ~1/10s); `homescreen.dart` after `_recordRouteMemory`; entitlement change.

**Same active-session guard applies:** the headless widget arm path must check `TrackingStateStore.isActive()` before `startTracking()` (shares the §3.1 fix).

**B — Wear OS (~1.5–2.5 weeks, needs a native `:wear` Kotlin module — Flutter does not belong on the watch).** MVP = "wrist wake": the phone pushes a `MessageClient` ping to the watch **when the phone alarm fires**; the watch buzzes + shows a full-screen dismiss. **Purely additive redundancy to the phone alarm — strengthens never-late, never gates it.** Uses the same signing/upload key it already has. Tile/complication + arm-from-wrist is a lower-ROI second step.

**Packages:** `home_widget: ^0.7.0`. Wear needs no new pub package (native module).

**Core-safety:** widget only mirrors the FGS notification and offers a safety-gated re-arm; Wear ping fires as additive redundancy alongside the phone alarm and cannot suppress it. No ad surface on any alarm/wake/lock surface.

**Tests:** `WidgetArmDecision.evaluate` truth table; `refresh()` locked/active/idle branches; headless arm refuses when active / no cached route / preflight blocks → deep-links instead; merged-manifest receiver presence check; Wear message round-trip (emulator).

## 3.7 Ads / IAP (the monetization foundation)

Already built and headless — this wave gives it surfaces (§2.2 paywall, §2.3 post-arrival strip) and closes the loops.

- **IAP:** one-time non-consumable `geowake_pro_onetime` (`PremiumProducts.proOneTime`), ₹199, through `MonetizationService` → `PurchaseBackend.buyOneTime` / `restorePurchases`. Add `queryPrice(productId)` to the interface + `IapPurchaseBackend` + `FakePurchaseBackend`, try/caught with ₹199 fallback.
- **Rewarded day-pass:** `AdService` rewarded → `facade.grantRewardedDayPass()`, offered only when `AdPolicy.shouldOfferRewardedUnlock`. Self-selects ad-tolerant users; zero forced friction.
- **Banners:** `GatedBannerAd` already collapses for Pro/no-fill. `AdPolicy.alwaysForbiddenPlacements` (alarm/wake/lockScreen) is **unchanged and never touched.** No interstitials anywhere; the only rewarded surfaces are the dismissible post-arrival strip and the paywall secondary CTA.
- **Ad-free:** automatic side-effect of `isPro`.

**Packages:** `google_mobile_ads ^6.0.0`, `in_app_purchase ^3.2.1` (both present).

**Core-safety:** the alarm/wake/lock denylist is invariant; the rewarded strip is gated behind `PostArrivalService.shouldShow(alarmDismissed:true)` + `isPro` short-circuit + dismissible/non-interstitial, so nothing competes with the ring.

**⚠ Reviewer note:** `queryPrice` failures and `premiumOrNull==null` reads must both fail-safe (₹199 fallback / show-paywall) so a store-metadata or init-timing failure never blanks or crashes the CTA.

**Tests:** paywall renders lead items first + localized price with ₹199 fallback; secondary CTA appears only when `shouldOfferRewardedUnlock`; `ProBadge` shows/hides on entitlement; `buyPro` bumps `tierListenable` and re-runs the gated action with no navigation; `restore` re-grants + hides ads; day-pass unlocks then re-locks after expiry (inject `nowMs`); post-arrival strip absent for Pro and until `ridesSinceLastAd >= cap`.

---

# 4. BUILD ORDER (Waves)

Ordered by value/effort/dependency. **[C] = client-only** (buildable + testable with Fake backends + test ad ids). **[F] = needs founder** (real ids/backend/module/assets).

### Wave 0 — Monetization surfacing (foundation; everything hangs off it)
- `ProGate` + `ProBadge` + `PaywallSource`; `tierListenable` on the facade; `queryPrice` + ₹199 fallback. **[C]**
- `GeoWakePaywallScreen`, wire the dead drawer "Go Premium" stub, `SettingsScreen` + `/settings`. **[C]** (real IAP price/purchase needs **[F]** `geowake_pro_onetime` SKU; ships against Fake until then.)
- `OnboardingScreen` + `gw_onboarded_v1`. **[C]**
- Dependency: none. Unblocks every gate below.

### Wave 1 — Post-arrival + basic share (viral loop + first revenue lever)
- `PostArrivalScreen` mounting the existing `PostArrivalCardWidget`, the fail-safe post-dismiss trigger (§2.3), FREE share row via `share_plus`. **[C]**
- Last-mile affiliate CTAs render regardless; deep-links need **[F]** affiliate ids/URLs (hide/generic until supplied).
- Rewarded post-arrival strip via existing `AdPolicy`/`AdService`; real fill needs **[F]** AdMob ids.
- Add `share_plus`, `url_launcher`. Depends on Wave 0.

### Wave 2 — Multi-alarm + unlimited saved routes (high value, engine already multi-target, client-only)
- `AlarmTarget`/`AlarmTargetSet` (with `uuid` opaque ids + `__dest__` sentinel), pipeline loop, additive intermediate fire-state map + `migrateAlarmState`, OS-kill restore, `RouteMemory.pinned`, `SavedRoutesScreen`. **[C]**
- Extends the b2eec7a at-scale gate. Depends on Wave 0 (gate) — otherwise self-contained; **no founder input.**

### Wave 3 — Custom / escalating alarm + smart snooze
- Sound profile + store gate + custom-sound manager + `SmartSnoozeController` (reachability-inversion deadline), `alarm_customization_screen`, `SNOOZE_ALARM` action. **[C]** (premium sound-pack **assets are [F]**; escalation/snooze/pick-your-own ship without them.)
- Add `file_picker`. Depends on Wave 0.

### Wave 4 — Recurring auto-arm (lead paywall item; client-only but platform-sensitive)
- Full `auto_arm_*` stack with the active-session guard, pre-arm channel, headless callback, `fetchDirectionsForArm` extraction. **[C]**
- Needs **[F]** only for the exact-alarm UX decision (SCHEDULE_EXACT_ALARM + graceful degrade; re-evaluate USE_EXACT_ALARM drop) and Play Data Safety copy.
- Add `android_alarm_manager_plus`, `uuid`. Depends on Wave 0 + C1 extraction.

### Wave 5 — Guardian / live share (lead paywall item; client-first, backend later)
- Add `canUseGuardianMode`; the **post-alarm multicast fix** (prerequisite, do first); `journey_share_service`, `guardian_service`, Noop backend, setup screen. **[C]** for basic/Noop.
- Live links + arrived push need **[F]** backend (`/v1/share`), App-Links domain + assetlinks + recipient page, FCM/SMS.
- Add `app_links`, `qr_flutter` (optional). Depends on Wave 1 (share surfaces).

### Wave 6 — Trip stats (retention + secondary growth loop, client-only)
- `pii_guard` extraction, `trip_record`, `trip_stats_service` with the **single-writer background-isolate bridge**, summary, `ShareStatCard` (pixelRatio 2.0), exporter, dashboard, `canUseTripStatsDashboard`. **[C]**, no founder input.
- Depends on Wave 1 (post-arrival nudge surface) + Wave 0 (gate).

### Wave 7 — Home widget (client-only) then Wear OS (needs founder module time)
- Home widget **[C]** (verify merged-manifest receiver; shares the active-session guard). Add `home_widget`.
- Wear OS wrist-wake **[F]** — native `:wear` Kotlin module. Do last (highest effort, lower ROI).
- Depends on Wave 0 (gate) + tracking state store.

### Wave 8 — Offline all-cities pack (Pro)
- `/offlineMaps` host + `canUseOfflineMaps`. Effort dominated by pack sourcing/hosting — treat as a later standalone. Depends on Wave 0.

> Data-consent screen (`/dataConsent`, `gw_data_consent_v1`) is a small UI-only, egress-free add that can land alongside Wave 0; the data *product* itself is out of scope for this feature set (needs a DPIA + backend — see §5).

---

# 5. EXTERNAL NEEDS — Founder Checklist

Nothing below is required to *build or test* any client wave (Fake backends + test ad ids + Noop share backend cover it). These gate *shipping* the corresponding surface.

1. **Play Console IAP** — create non-consumable **`geowake_pro_onetime`** priced ₹199 (must match `PremiumProducts.proOneTime`). Prerequisite for every real Pro unlock; nothing in code creates it.
2. **AdMob** — real app id (AndroidManifest meta-data) + real banner / interstitial / rewarded unit ids fed to `AdService.configure()` via build/remote-config. Test ids ship until then.
3. **Last-mile affiliate / deep-link partners** — Rapido/Ola/Uber affiliate ids + deep-link URLs (optionally Swiggy/Zomato) for the post-arrival card CTAs. Card renders regardless; ride CTA hidden or generic until supplied.
4. **Hosted Privacy Policy + Terms URLs** (linked from paywall, settings, consent) + the Play Data Safety declaration (note background location for scheduled auto-arm + widget).
5. **Premium alarm sound-pack assets** — licensed/royalty-free `.ogg`/`.mp3` under `assets/ringtones/premium/` (+ pubspec) + license. Escalation/snooze/pick-your-own ship without them.
6. **Exact-alarm decision** — confirm SCHEDULE_EXACT_ALARM + graceful degrade to inexact windowed; re-evaluate the USE_EXACT_ALARM drop (Android 14 Play restriction) per app memory.
7. **Live-share backend** (`/v1/share`: Cloud Run / Firebase Functions + TTL KV) + **App-Links domain** (e.g. `geo.wake`) with `/.well-known/assetlinks.json` + a lightweight recipient web page at `/j/{id}`. Firebase Dynamic Links is shut down (2025) — use native App Links via `app_links`.
8. **FCM project + server key** (Guardian "arrived safely" in-app push) + optional India **DLT-registered SMS** sender for contacts without the app.
9. **Play Store referrer** setup to capture `?referrer=share_<id>` install attribution.
10. **Wear OS** — founder module time for the native `:wear` Kotlin module (reuses existing signing/upload key; no new account).
11. **Data product (out of scope here, later only)** — an Indian data-protection lawyer's DPIA / anonymisation sign-off and, only when egress is built, a backend aggregation sink. The `/dataConsent` UI wave is egress-free and needs none of this.

---

*Every user-facing string says **GeoWake**. Every paywall routes through **one** `ProGate.run`. The arm → track → alarm spine and the basic share loop are untouched and free by construction.*
