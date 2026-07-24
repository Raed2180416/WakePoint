// Regression test for the shared-Completer race between IapPurchaseBackend's
// restore() (user-triggered, from the paywall's "Restore purchase" button) and
// queryPastPurchases() (launch-time reconciliation, fired unawaited from
// MonetizationService.init on every app start).
//
// BUG (fixed): both methods wrote the SAME `_restoreCompleter` instance field.
// If a user tapped Restore while queryPastPurchases() was still in flight, the
// second call's `_restoreCompleter = Completer()` silently clobbered the
// first's reference, and whichever call's `finally` ran first nulled the field
// out from under the still-pending other call — which then either hung on its
// own timeout fallback or threw a null-check TypeError. The fix gives each
// call its own completer, queued in a list that `_onPurchases` drains in full.
//
// This drives IapPurchaseBackend against a fake InAppPurchasePlatform (the
// plugin's own supported testing seam — see
// in_app_purchase_platform_interface's `InAppPurchasePlatform.instance`
// setter) so the real concurrency path is exercised, not just PremiumService's
// entitlement logic (already covered by FakePurchaseBackend elsewhere).

import 'dart:async';

import 'package:flutter/foundation.dart' show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart' show TargetPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase_platform_interface/in_app_purchase_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:geowake2/services/monetization/purchase_backend_impl.dart';

/// A minimal fake store platform: restorePurchases() is a no-op (the test
/// drives the purchase stream directly), so timing is fully test-controlled.
class _FakeIapPlatform extends InAppPurchasePlatform {
  final StreamController<List<PurchaseDetails>> _ctrl =
      StreamController<List<PurchaseDetails>>.broadcast();

  int restoreCalls = 0;

  @override
  Stream<List<PurchaseDetails>> get purchaseStream => _ctrl.stream;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<void> restorePurchases({String? applicationUserName}) async {
    restoreCalls++;
    // Real plugins asynchronously replay purchases on the stream after this
    // resolves; the test emits explicitly via [emit] to control timing.
  }

  @override
  Future<void> completePurchase(PurchaseDetails purchase) async {}

  void emit(List<PurchaseDetails> purchases) => _ctrl.add(purchases);

  Future<void> close() => _ctrl.close();
}

PurchaseDetails _restored(String productId) => PurchaseDetails(
      productID: productId,
      verificationData: PurchaseVerificationData(
        localVerificationData: 'local',
        serverVerificationData: 'server',
        source: 'test',
      ),
      transactionDate: DateTime.now().millisecondsSinceEpoch.toString(),
      status: PurchaseStatus.restored,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeIapPlatform fake;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // IapPurchaseBackend's constructor touches InAppPurchase.instance, which
    // — the FIRST time it happens in this process — auto-registers the real
    // platform adapter (InAppPurchaseAndroidPlatform/StoreKitPlatform) for
    // Android/iOS/macOS, silently overwriting InAppPurchasePlatform.instance
    // and clobbering the fake below. Forcing a non-mobile target platform
    // skips that registration branch entirely, so the fake set immediately
    // after always sticks.
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    fake = _FakeIapPlatform();
    InAppPurchasePlatform.instance = fake;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    fake.close();
  });

  group('IapPurchaseBackend — restore()/queryPastPurchases() concurrency', () {
    test(
        'a concurrent restore() and queryPastPurchases() BOTH resolve '
        'IMMEDIATELY from a single stream event (no clobbered completer, no '
        'fall-through to the multi-second timeout fallback)', () async {
      final backend = IapPurchaseBackend();
      await backend.init();

      // Launch-time reconciliation starts first (as MonetizationService.init
      // does, unawaited) and is allowed to reach its own "wait for the
      // stream" point BEFORE restore() starts — exactly the interleaving
      // that clobbers a single shared completer field: queryPastPurchases()
      // is already parked on (what should be) its own completer when
      // restore() runs and reassigns it.
      final queryFuture = backend.queryPastPurchases();
      await Future<void>.delayed(Duration.zero);

      // ... then the user taps "Restore purchase" while it's still in flight.
      final restoreFuture = backend.restore();
      await Future<void>.delayed(Duration.zero);

      // A single stream event should satisfy BOTH pending waiters.
      final stopwatch = Stopwatch()..start();
      fake.emit([_restored('gw_pro_onetime')]);

      // queryPastPurchases() returns void; awaiting it is itself part of the
      // assertion that it completed promptly rather than hanging.
      await queryFuture;
      final restoreResult = await restoreFuture;
      stopwatch.stop();

      expect(restoreResult, contains('gw_pro_onetime'),
          reason: 'restore() must observe the restored purchase');
      // The regression this guards: with a SHARED completer field, one of
      // the two calls ends up awaiting an orphaned/wrong completer that
      // `_onPurchases` never completes, so it only resolves via its own
      // internal timeout fallback (3s for queryPastPurchases, 5s for
      // restore()) — multiple seconds later than the immediate stream
      // signal. A generous 1s bound comfortably separates "resolved via the
      // stream" from "fell through to a multi-second timeout fallback".
      expect(stopwatch.elapsedMilliseconds, lessThan(1000),
          reason: 'both calls must resolve immediately from the single '
              'stream event, not fall through to a multi-second timeout '
              'fallback (a symptom of a clobbered/orphaned completer)');
    });

    test(
        'restore() started AFTER queryPastPurchases() already completed still '
        'resolves correctly (no leftover state from the earlier call)',
        () async {
      final backend = IapPurchaseBackend();
      await backend.init();

      final queryFuture = backend.queryPastPurchases();
      fake.emit([_restored('gw_pro_onetime')]);
      await queryFuture;

      // A second, later restore() (e.g. the user taps the button afterwards)
      // must not be affected by the first call's now-removed completer.
      final restoreFuture = backend.restore();
      await Future<void>.delayed(Duration.zero);
      fake.emit([_restored('gw_daypass')]);

      final restored = await restoreFuture.timeout(const Duration(seconds: 2));
      expect(restored, containsAll(<String>{'gw_pro_onetime', 'gw_daypass'}));
    });

    test('a plain single restore() with no concurrent call still works',
        () async {
      final backend = IapPurchaseBackend();
      await backend.init();

      final restoreFuture = backend.restore();
      await Future<void>.delayed(Duration.zero);
      fake.emit([_restored('gw_pro_onetime')]);

      final restored = await restoreFuture.timeout(const Duration(seconds: 2));
      expect(restored, {'gw_pro_onetime'});
      expect(fake.restoreCalls, 1);
    });
  });
}
