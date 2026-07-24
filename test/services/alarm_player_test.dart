// Regression test: a custom alarm ringtone must never keep playing after the
// entitlement that unlocked it (Pro / an active rewarded day-pass) lapses.
//
// BUG (fixed): RingtonesScreen wrote the chosen ringtone to the unscoped
// 'selected_ringtone' SharedPreferences key with no entitlement check, and
// AlarmPlayer.playSelected() — the real wake-alarm playback path — read that
// key back unconditionally. A user who unlocked Pro via a 24h rewarded
// day-pass, picked a custom ringtone, then let the pass expire kept the
// custom sound forever, since nothing re-validated
// canUseCustomAlarmSounds at playback time.
//
// The fix re-checks the entitlement at play-time and falls back to the free
// default sound — never toward silence — whenever it isn't currently active.
//
// AlarmPlayer talks to the real audioplayers platform channel, which isn't
// registered headless, so it always take the "audio unavailable" branch and
// never actually plays anything in this test environment. The resolved
// asset PATH is still computed either way, so the test observes it via the
// @visibleForTesting seam (AlarmPlayer.lastResolvedAssetPathForTests) rather
// than mocking the platform channel.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:geowake2/services/alarm_player.dart';
import 'package:geowake2/services/monetization/monetization_service.dart';
import 'package:geowake2/services/monetization/premium_service.dart';
import 'package:geowake2/services/monetization/purchase_backend.dart';

const String _customRingtone = 'assets/ringtones/Custom Bell.ogg';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final mon = MonetizationService.instance;

  setUpAll(() async {
    // MonetizationService is a process-wide singleton with a one-shot init()
    // (see monetization_journey_test.dart) — assemble it once, headlessly,
    // with a FakePurchaseBackend so premiumOrNull is non-null for every test
    // below; each test then swaps `mon.premium` directly for the entitlement
    // state it wants to exercise.
    await mon.init(backendOverride: FakePurchaseBackend());
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'selected_ringtone': _customRingtone,
    });
  });

  test('an active Pro entitlement plays the saved custom ringtone', () async {
    mon.premium = PremiumService(backend: FakePurchaseBackend());
    await mon.premium.buyPro();
    expect(mon.premiumOrNull?.canUseCustomAlarmSounds, isTrue);

    await AlarmPlayer.playSelected();

    expect(AlarmPlayer.lastResolvedAssetPathForTests, _customRingtone);
  });

  test(
      'a lapsed entitlement (free tier) falls back to the default sound, '
      'even though a custom ringtone is still saved in prefs', () async {
    mon.premium = PremiumService(backend: FakePurchaseBackend());
    expect(mon.premiumOrNull?.canUseCustomAlarmSounds, isFalse,
        reason: 'a fresh free-tier PremiumService must not unlock custom '
            'ringtones');

    await AlarmPlayer.playSelected();

    expect(AlarmPlayer.lastResolvedAssetPathForTests,
        AlarmPlayer.defaultRingtoneAsset,
        reason: 'must fail toward the default sound, never keep playing an '
            'unentitled custom ringtone');
  });

  test(
      'an EXPIRED rewarded day-pass falls back to the default sound (the '
      'exact reported leak: buy a day-pass, pick a ringtone, let it lapse)',
      () async {
    var clock = 1000;
    mon.premium =
        PremiumService(backend: FakePurchaseBackend(), nowMs: () => clock);
    await mon.premium.grantRewardedDayPass(duration: const Duration(hours: 24));
    expect(mon.premiumOrNull?.canUseCustomAlarmSounds, isTrue,
        reason: 'within the pass window, custom ringtones are unlocked');

    // Pick up a custom ringtone while entitled (mirrors RingtonesScreen's
    // unconditional prefs write).
    await AlarmPlayer.playSelected();
    expect(AlarmPlayer.lastResolvedAssetPathForTests, _customRingtone);

    // The pass expires — nothing clears 'selected_ringtone' from prefs.
    clock = 1000 + const Duration(hours: 25).inMilliseconds;
    expect(mon.premiumOrNull?.canUseCustomAlarmSounds, isFalse);

    await AlarmPlayer.playSelected();

    expect(AlarmPlayer.lastResolvedAssetPathForTests,
        AlarmPlayer.defaultRingtoneAsset,
        reason: 'the real wake alarm must not keep the custom sound once '
            'the day-pass that unlocked it has expired');
  });

  test('no saved ringtone at all always resolves to the default, entitled '
      'or not', () async {
    SharedPreferences.setMockInitialValues({});
    mon.premium = PremiumService(backend: FakePurchaseBackend());
    await mon.premium.buyPro();

    await AlarmPlayer.playSelected();

    expect(AlarmPlayer.lastResolvedAssetPathForTests,
        AlarmPlayer.defaultRingtoneAsset);
  });
}
