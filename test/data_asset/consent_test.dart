import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/data_asset/data_asset_config.dart';
import 'package:geowake2/services/data_asset/mobility_consent_service.dart';

/// In-memory persistence pair for deterministic, device-free tests.
({
  Future<String?> Function(String) load,
  Future<void> Function(String, String) save,
  Map<String, String> store,
}) memStore([Map<String, String>? seed]) {
  final m = <String, String>{...?seed};
  return (
    load: (k) async => m[k],
    save: (k, v) async => m[k] = v,
    store: m,
  );
}

void main() {
  group('MobilityConsentService', () {
    test('default is DISABLED (fresh install)', () async {
      final s = MobilityConsentService();
      await s.load();
      expect(s.isSharingEnabled, isFalse);
    });

    test('corrupt/missing blob resolves to DISABLED (fail-safe)', () async {
      final store = memStore({MobilityConsentService.persistKey: '{not json'});
      final s = MobilityConsentService(load: store.load, save: store.save);
      await s.load();
      expect(s.isSharingEnabled, isFalse);
    });

    test('grant/withdraw round-trip', () async {
      final store = memStore();
      final s = MobilityConsentService(load: store.load, save: store.save);
      await s.load();
      await s.grant();
      expect(s.isSharingEnabled, isTrue);

      // Rehydrate a fresh instance from the same store.
      final s2 = MobilityConsentService(load: store.load, save: store.save);
      await s2.load();
      expect(s2.isSharingEnabled, isTrue);

      await s2.withdraw();
      expect(s2.isSharingEnabled, isFalse);
      expect(s2.withdrawnAtMs, greaterThan(0));
    });

    test('noticeVersion bump forces re-consent', () async {
      // Persist an enabled grant under a STALE notice version.
      final store = memStore({
        MobilityConsentService.persistKey:
            '{"enabled":true,"noticeVersion":"stale-v0","grantedAtMs":1,"withdrawnAtMs":0}'
      });
      final s = MobilityConsentService(load: store.load, save: store.save);
      await s.load();
      // Raw flag is on, but the effective gate is OFF until re-consent.
      expect(s.rawEnabledFlag, isTrue);
      expect(s.noticeVersion, isNot(kConsentNoticeVersion));
      expect(s.isSharingEnabled, isFalse);

      await s.grant();
      expect(s.noticeVersion, kConsentNoticeVersion);
      expect(s.isSharingEnabled, isTrue);
    });

    test('withdraw invokes the erasure hook exactly once', () async {
      var erasures = 0;
      final s = MobilityConsentService()..onWithdraw = () async => erasures++;
      await s.load();
      await s.grant();
      await s.withdraw();
      expect(erasures, 1);
      expect(s.isSharingEnabled, isFalse);
    });

    test('withdraw still disables even if the erasure hook throws', () async {
      final s = MobilityConsentService()
        ..onWithdraw = () async => throw StateError('boom');
      await s.grant();
      await s.withdraw(); // must not throw
      expect(s.isSharingEnabled, isFalse);
    });

    test('consentReceiptJson mentions GeoWake and the guarantees', () async {
      final s = MobilityConsentService();
      await s.grant();
      final r = s.consentReceiptJson();
      expect(r.contains('GeoWake'), isTrue);
      expect(r.contains('100'), isTrue); // k threshold
    });
  });
}
