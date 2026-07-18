// Deterministic, headless proof for the delivery-channel preflight completeness
// work (BACKLOG #17 DND, #18 full-screen intent, #19 fix-action routing,
// #20 aggressive-OEM battery => BLOCK). Pure flutter test — no device, no real
// plugin: OS states are driven through FakeReliabilityProbe, and the runner's
// fix-action routing is exercised through an injectable spy launcher (so no
// platform channel is ever touched).
import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/reliability/reliability_preflight_runner.dart';
import 'package:geowake2/services/reliability/reliability_preflight_service.dart';

/// Words that would betray implementation jargon in a user-facing string.
const List<String> _jargon = <String>[
  'permission',
  'optimization',
  'bypass',
  'interruption',
  'policy access',
  'sdk',
  'boolean',
  'null',
];

Future<PreflightResult> _check({
  bool exactAlarm = true,
  bool batteryExempt = true,
  bool notifications = true,
  bool precise = true,
  bool dndBypass = true,
  bool dnd = false,
  bool fsiAllowed = true,
  String oem = 'google',
}) {
  final probe = FakeReliabilityProbe(
    exactAlarm: exactAlarm,
    batteryExempt: batteryExempt,
    notifications: notifications,
    precise: precise,
    dndBypass: dndBypass,
    dnd: dnd,
    fsiAllowed: fsiAllowed,
    oem: oem,
  );
  return ReliabilityPreflightService(probe).check();
}

/// Records which launcher method fired, so we can assert #19 routing without a
/// real platform channel.
class _SpyLauncher extends PreflightFixLauncher {
  final List<String> calls = <String>[];

  @override
  Future<void> openNotificationSettings() async => calls.add('notification');
  @override
  Future<void> openExactAlarmSettings() async => calls.add('exactAlarm');
  @override
  Future<void> openBatteryOptimizationSettings() async => calls.add('battery');
  @override
  Future<void> openLocationSettings() async => calls.add('location');
  @override
  Future<void> openDndAccessSettings() async => calls.add('dnd');
  @override
  Future<void> openFullScreenIntentSettings() async => calls.add('fsi');
  @override
  Future<void> openAppSettingsFallback() async => calls.add('fallback');
}

void main() {
  group('#17 Do Not Disturb', () {
    test('DND active + no bypass => WARN issue, openDndAccessSettings', () async {
      final r = await _check(dnd: true, dndBypass: false);
      final issue = r.issueOf(PreflightIssueCode.dnd);
      expect(issue, isNotNull);
      expect(issue!.severity, PreflightSeverity.warn);
      expect(r.level, PreflightLevel.warn);
      expect(issue.fixAction, PreflightFixAction.openDndAccessSettings);
    });

    test('DND active but bypass granted => no DND issue', () async {
      final r = await _check(dnd: true, dndBypass: true);
      expect(r.issueOf(PreflightIssueCode.dnd), isNull);
      expect(r.level, PreflightLevel.ok);
    });

    test('DND off (even without bypass) => no DND issue', () async {
      final r = await _check(dnd: false, dndBypass: false);
      expect(r.issueOf(PreflightIssueCode.dnd), isNull);
      expect(r.level, PreflightLevel.ok);
    });
  });

  group('#18 full-screen intent', () {
    test('FSI not allowed => WARN issue, openFullScreenIntentSettings', () async {
      final r = await _check(fsiAllowed: false);
      final issue = r.issueOf(PreflightIssueCode.fullScreenIntent);
      expect(issue, isNotNull);
      expect(issue!.severity, PreflightSeverity.warn);
      expect(r.level, PreflightLevel.warn);
      expect(issue.fixAction, PreflightFixAction.openFullScreenIntentSettings);
    });

    test('FSI allowed => no FSI issue', () async {
      final r = await _check(fsiAllowed: true);
      expect(r.issueOf(PreflightIssueCode.fullScreenIntent), isNull);
    });
  });

  group('#20 aggressive OEM + no battery exemption => WARN (founder toggle to BLOCK)', () {
    // Integrator note: #20 is KEPT AT WARN (not elevated to BLOCK) so the
    // never-late core alarm is not gated on a probabilistic battery-exemption
    // setup step. The block-elevation is a one-line founder toggle in
    // reliability_preflight_service.dart. These assertions track the shipped
    // WARN behaviour.
    test('aggressive OEM (xiaomi) + !batteryExempt => WARN, not blocked', () async {
      final r = await _check(batteryExempt: false, oem: 'xiaomi');
      final issue = r.issueOf(PreflightIssueCode.batteryOptimization)!;
      expect(issue.severity, PreflightSeverity.warn);
      expect(r.level, PreflightLevel.warn);
      expect(r.isBlocked, isFalse);
    });

    test('stock OEM (google) + !batteryExempt => advisory, warn level', () async {
      final r = await _check(batteryExempt: false, oem: 'google');
      final issue = r.issueOf(PreflightIssueCode.batteryOptimization)!;
      expect(issue.severity, PreflightSeverity.advisory);
      expect(r.level, PreflightLevel.warn);
      expect(r.isBlocked, isFalse);
    });

    test('every India-mix OEM warns (not blocks) when not battery-exempt',
        () async {
      for (final oem in const [
        'xiaomi', 'redmi', 'poco', 'oppo', 'realme', 'vivo', 'iqoo',
        'oneplus', 'honor', 'huawei', 'samsung', 'tecno', 'infinix',
      ]) {
        final r = await _check(batteryExempt: false, oem: oem);
        expect(r.level, PreflightLevel.warn, reason: oem);
        expect(r.isBlocked, isFalse, reason: oem);
      }
    });
  });

  group('#19 applyReliabilityFix routes each action to its own deep-link', () {
    test('each known action calls exactly its launcher method', () async {
      final cases = <String, String>{
        PreflightFixAction.openNotificationSettings: 'notification',
        PreflightFixAction.openExactAlarmSettings: 'exactAlarm',
        PreflightFixAction.openBatteryOptimizationSettings: 'battery',
        PreflightFixAction.openLocationSettings: 'location',
        PreflightFixAction.openDndAccessSettings: 'dnd',
        PreflightFixAction.openFullScreenIntentSettings: 'fsi',
      };
      for (final entry in cases.entries) {
        final spy = _SpyLauncher();
        await applyReliabilityFix(entry.key, launcher: spy);
        expect(spy.calls, [entry.value],
            reason: '${entry.key} must route to ${entry.value} only');
      }
    });

    test('a known action NEVER falls through to the app-settings fallback',
        () async {
      for (final action in const [
        PreflightFixAction.openNotificationSettings,
        PreflightFixAction.openExactAlarmSettings,
        PreflightFixAction.openBatteryOptimizationSettings,
        PreflightFixAction.openLocationSettings,
        PreflightFixAction.openDndAccessSettings,
        PreflightFixAction.openFullScreenIntentSettings,
      ]) {
        final spy = _SpyLauncher();
        await applyReliabilityFix(action, launcher: spy);
        expect(spy.calls, isNot(contains('fallback')), reason: action);
      }
    });

    test('an UNKNOWN action falls back to the app settings page', () async {
      final spy = _SpyLauncher();
      await applyReliabilityFix('someFutureAction', launcher: spy);
      expect(spy.calls, ['fallback']);
    });
  });

  group('every fix action a preflight can emit has a launcher route', () {
    test('no emitted fixAction hits the fallback', () async {
      // Trip every issue at once so the result carries all six fix actions.
      final r = await _check(
        notifications: false,
        exactAlarm: false,
        batteryExempt: false,
        precise: false,
        dnd: true,
        dndBypass: false,
        fsiAllowed: false,
        oem: 'xiaomi',
      );
      expect(r.issues, hasLength(6));
      for (final action in r.fixActions) {
        final spy = _SpyLauncher();
        await applyReliabilityFix(action, launcher: spy);
        expect(spy.calls, isNot(contains('fallback')),
            reason: '"$action" must have a real deep-link route');
      }
    });
  });

  group('new issue copy is user-facing (jargon-free)', () {
    test('DND + FSI copy carries no implementation jargon', () async {
      final r = await _check(dnd: true, dndBypass: false, fsiAllowed: false);
      final issues = [
        r.issueOf(PreflightIssueCode.dnd)!,
        r.issueOf(PreflightIssueCode.fullScreenIntent)!,
      ];
      for (final issue in issues) {
        expect(issue.title.trim(), isNotEmpty);
        expect(issue.message.trim().length, greaterThan(12));
        final haystack = '${issue.title}\n${issue.message}'.toLowerCase();
        for (final term in _jargon) {
          expect(haystack.contains(term), isFalse,
              reason: '${issue.code} leaked jargon "$term"');
        }
      }
    });
  });
}
