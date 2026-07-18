// Deterministic, headless tests for the arm-time reliability preflight
// (HANDOFF §1 P1.3, §3). No device, no real plugin — every permission-state
// combination is driven through a FakeReliabilityProbe.
import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/reliability/reliability_preflight_service.dart';

/// Words that would betray implementation jargon in a user-facing string. If any
/// of these appears in a title or message, the copy has leaked internals.
const List<String> _jargon = <String>[
  'exact alarm',
  'exactalarm',
  'doze',
  'foreground',
  'fgs',
  'permission',
  'optimization',
  'whitelist',
  'exemption',
  'kalman',
  'ekf',
  'geofenc',
  'boolean',
  'null',
  'sdk',
];

Future<PreflightResult> _check({
  bool exactAlarm = true,
  bool batteryExempt = true,
  bool notifications = true,
  bool precise = true,
  String oem = 'google',
}) {
  final probe = FakeReliabilityProbe(
    exactAlarm: exactAlarm,
    batteryExempt: batteryExempt,
    notifications: notifications,
    precise: precise,
    oem: oem,
  );
  return ReliabilityPreflightService(probe).check();
}

void main() {
  group('overall level per permission-state combination', () {
    test('all preconditions satisfied => OK, no issues', () async {
      final r = await _check();
      expect(r.level, PreflightLevel.ok);
      expect(r.isOk, isTrue);
      expect(r.issues, isEmpty);
    });

    test('notifications OFF => BLOCK (the alarm can never show)', () async {
      final r = await _check(notifications: false);
      expect(r.level, PreflightLevel.block);
      expect(r.isBlocked, isTrue);
      final issue = r.issueOf(PreflightIssueCode.notifications);
      expect(issue, isNotNull);
      expect(issue!.severity, PreflightSeverity.block);
      expect(issue.fixAction, PreflightFixAction.openNotificationSettings);
    });

    test('BLOCK dominates even when other issues are present', () async {
      final r = await _check(
        notifications: false,
        exactAlarm: false,
        batteryExempt: false,
        precise: false,
        oem: 'xiaomi',
      );
      expect(r.level, PreflightLevel.block);
      // and the notifications issue is ranked first (most severe).
      expect(r.issues.first.code, PreflightIssueCode.notifications);
      expect(r.blocking, hasLength(1));
    });

    test('approximate-only location => WARN', () async {
      final r = await _check(precise: false);
      expect(r.level, PreflightLevel.warn);
      final issue = r.issueOf(PreflightIssueCode.preciseLocation);
      expect(issue, isNotNull);
      expect(issue!.severity, PreflightSeverity.warn);
      expect(issue.fixAction, PreflightFixAction.openLocationSettings);
    });

    test('missing exact-alarm => WARN level on any OEM', () async {
      expect((await _check(exactAlarm: false, oem: 'google')).level,
          PreflightLevel.warn);
      expect((await _check(exactAlarm: false, oem: 'xiaomi')).level,
          PreflightLevel.warn);
    });

    test('battery-opt not exempt => WARN level on any OEM', () async {
      expect((await _check(batteryExempt: false, oem: 'google')).level,
          PreflightLevel.warn);
      expect((await _check(batteryExempt: false, oem: 'oppo')).level,
          PreflightLevel.warn);
    });
  });

  group('aggressive vs non-aggressive OEM sharpens severity', () {
    test('exact-alarm: aggressive OEM warns more strongly than a stock one',
        () async {
      final aggressive = await _check(exactAlarm: false, oem: 'Xiaomi');
      final stock = await _check(exactAlarm: false, oem: 'Google');

      final aIssue = aggressive.issueOf(PreflightIssueCode.exactAlarm)!;
      final sIssue = stock.issueOf(PreflightIssueCode.exactAlarm)!;

      expect(aIssue.severity, PreflightSeverity.warn);
      expect(sIssue.severity, PreflightSeverity.advisory);
      // warn is strictly more severe than advisory (lower index = more severe).
      expect(aIssue.severity.index, lessThan(sIssue.severity.index));
      // both still surface as a warning to the rider.
      expect(aggressive.level, PreflightLevel.warn);
      expect(stock.level, PreflightLevel.warn);
    });

    test('battery: aggressive OEM warns more strongly than a stock one',
        () async {
      final aggressive = await _check(batteryExempt: false, oem: 'realme');
      final stock = await _check(batteryExempt: false, oem: 'google');

      final aIssue =
          aggressive.issueOf(PreflightIssueCode.batteryOptimization)!;
      final sIssue = stock.issueOf(PreflightIssueCode.batteryOptimization)!;

      expect(aIssue.severity, PreflightSeverity.warn);
      expect(sIssue.severity, PreflightSeverity.advisory);
      expect(aIssue.severity.index, lessThan(sIssue.severity.index));
    });
  });

  group('isAggressiveOem (dontkillmyapp 5/5 + India device mix)', () {
    test('known aggressive OEMs are flagged (case-insensitive)', () {
      for (final oem in <String>[
        'Xiaomi',
        'Redmi',
        'POCO',
        'Oppo',
        'realme',
        'vivo',
        'iQOO',
        'HONOR',
        'HUAWEI',
        'samsung',
        'OnePlus',
      ]) {
        expect(ReliabilityPreflightService.isAggressiveOem(oem), isTrue,
            reason: '$oem should be treated as aggressive');
      }
    });

    test('stock / unknown OEMs are not flagged', () {
      for (final oem in <String>['Google', 'Pixel', 'motorola', '', '   ']) {
        expect(ReliabilityPreflightService.isAggressiveOem(oem), isFalse,
            reason: '$oem should NOT be treated as aggressive');
      }
    });
  });

  group('issue shape and ordering', () {
    test('every issue has a severity, a fix action, and copy', () async {
      final r = await _check(
        notifications: false,
        exactAlarm: false,
        batteryExempt: false,
        precise: false,
        oem: 'vivo',
      );
      expect(r.issues, hasLength(4));
      const knownActions = <String>{
        PreflightFixAction.openNotificationSettings,
        PreflightFixAction.openExactAlarmSettings,
        PreflightFixAction.openBatteryOptimizationSettings,
        PreflightFixAction.openLocationSettings,
      };
      for (final issue in r.issues) {
        expect(issue.title.trim(), isNotEmpty);
        expect(issue.message.trim(), isNotEmpty);
        expect(knownActions, contains(issue.fixAction));
        expect(issue.code.trim(), isNotEmpty);
      }
    });

    test('issues are sorted most-severe first', () async {
      // aggressive OEM so exact-alarm/battery are warn (not advisory), giving a
      // block + several warns to order.
      final r = await _check(
        notifications: false,
        exactAlarm: false,
        batteryExempt: false,
        precise: false,
        oem: 'oppo',
      );
      for (var i = 1; i < r.issues.length; i++) {
        expect(r.issues[i - 1].severity.index,
            lessThanOrEqualTo(r.issues[i].severity.index),
            reason: 'issues must be ordered most-severe first');
      }
      expect(r.issues.first.severity, PreflightSeverity.block);
    });

    test('correct fix action is attached to each precondition', () async {
      final r = await _check(
        exactAlarm: false,
        batteryExempt: false,
        precise: false,
        oem: 'honor',
      );
      expect(r.issueOf(PreflightIssueCode.exactAlarm)!.fixAction,
          PreflightFixAction.openExactAlarmSettings);
      expect(r.issueOf(PreflightIssueCode.batteryOptimization)!.fixAction,
          PreflightFixAction.openBatteryOptimizationSettings);
      expect(r.issueOf(PreflightIssueCode.preciseLocation)!.fixAction,
          PreflightFixAction.openLocationSettings);
    });
  });

  group('user-facing copy is jargon-free', () {
    test('no title or message contains implementation jargon', () async {
      // Generate the full catalogue of issues across OEM aggressiveness.
      final results = <PreflightResult>[
        await _check(
          notifications: false,
          exactAlarm: false,
          batteryExempt: false,
          precise: false,
          oem: 'xiaomi',
        ),
        await _check(
          notifications: false,
          exactAlarm: false,
          batteryExempt: false,
          precise: false,
          oem: 'google',
        ),
      ];
      for (final r in results) {
        for (final issue in r.issues) {
          final haystack = '${issue.title}\n${issue.message}'.toLowerCase();
          for (final term in _jargon) {
            expect(haystack.contains(term), isFalse,
                reason: 'issue "${issue.code}" copy leaked jargon: "$term"');
          }
        }
      }
    });
  });

  group('level/severity mapping helper', () {
    test('block=>block, warn/advisory=>warn', () {
      expect(
          ReliabilityPreflightService.levelForSeverity(PreflightSeverity.block),
          PreflightLevel.block);
      expect(
          ReliabilityPreflightService.levelForSeverity(PreflightSeverity.warn),
          PreflightLevel.warn);
      expect(
          ReliabilityPreflightService.levelForSeverity(
              PreflightSeverity.advisory),
          PreflightLevel.warn);
    });
  });
}
