// EXHAUSTIVE combinatorial coverage for the arm-time reliability preflight
// (HANDOFF §1 P1.3, §3). Enumerates ALL 2^4 combinations of the four OS states
// {notifications, exactAlarm, batteryExempt, precise} crossed with aggressive vs
// non-aggressive OEM, driven headlessly through FakeReliabilityProbe.
//
// The cardinal sin of a wake-alarm is firing LATE or NEVER, so these tests bite
// hardest on:
//   * notifications OFF  => the alarm literally can never show  => hard BLOCK in
//     EVERY one of the 16 combinations, on EVERY OEM; and
//   * a fire-late risk (exact-alarm / battery / precise) must NEVER be silently
//     dropped — if the state is bad, an issue is ALWAYS surfaced.
//
// Separate from the existing reliability_preflight_test.dart: that file spot-
// checks representative cases; this file proves the full truth table.
import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/reliability/reliability_preflight_service.dart';

/// The four independent boolean OS states; `true` is the good/safe value.
class _Flags {
  final bool notifications;
  final bool exactAlarm;
  final bool batteryExempt;
  final bool precise;
  const _Flags(
      this.notifications, this.exactAlarm, this.batteryExempt, this.precise);

  @override
  String toString() => 'notif=$notifications exact=$exactAlarm '
      'batt=$batteryExempt precise=$precise';
}

/// All 16 combinations of the four booleans, eagerly materialised so they can be
/// consumed at group-collection time.
List<_Flags> _allFlagCombos() {
  final out = <_Flags>[];
  for (final n in const [true, false]) {
    for (final e in const [true, false]) {
      for (final b in const [true, false]) {
        for (final p in const [true, false]) {
          out.add(_Flags(n, e, b, p));
        }
      }
    }
  }
  return out;
}

Future<PreflightResult> _run(_Flags f, String oem) {
  final probe = FakeReliabilityProbe(
    notifications: f.notifications,
    exactAlarm: f.exactAlarm,
    batteryExempt: f.batteryExempt,
    precise: f.precise,
    oem: oem,
  );
  return ReliabilityPreflightService(probe).check();
}

/// Pure oracle for the expected overall level. By design this is
/// OEM-INDEPENDENT: aggressiveness only sharpens per-issue severity, and both
/// warn+advisory roll up to the same overall warn level.
PreflightLevel _expectedLevel(_Flags f) {
  if (!f.notifications) return PreflightLevel.block;
  if (!f.exactAlarm || !f.batteryExempt || !f.precise) {
    return PreflightLevel.warn;
  }
  return PreflightLevel.ok;
}

int _expectedIssueCount(_Flags f) {
  var n = 0;
  if (!f.notifications) n++;
  if (!f.exactAlarm) n++;
  if (!f.batteryExempt) n++;
  if (!f.precise) n++;
  return n;
}

// The India device mix the roll-up must treat as aggressive (HANDOFF §1).
const List<String> _indiaMix = <String>[
  'xiaomi',
  'redmi',
  'poco',
  'oppo',
  'realme',
  'vivo',
  'iqoo',
  'oneplus',
  'honor',
  'huawei',
];

// Stock / unknown brands the roll-up must NOT treat as aggressive.
const List<String> _stockOems = <String>['google', 'nothing', 'motorola'];

const Set<String> _knownActions = <String>{
  PreflightFixAction.openNotificationSettings,
  PreflightFixAction.openExactAlarmSettings,
  PreflightFixAction.openBatteryOptimizationSettings,
  PreflightFixAction.openLocationSettings,
};

String _expectedActionFor(String code) {
  switch (code) {
    case PreflightIssueCode.notifications:
      return PreflightFixAction.openNotificationSettings;
    case PreflightIssueCode.exactAlarm:
      return PreflightFixAction.openExactAlarmSettings;
    case PreflightIssueCode.batteryOptimization:
      return PreflightFixAction.openBatteryOptimizationSettings;
    case PreflightIssueCode.preciseLocation:
      return PreflightFixAction.openLocationSettings;
    default:
      fail('unexpected issue code: "$code"');
  }
}

/// Asserts the three level getters agree with [PreflightResult.level], are
/// mutually exclusive, and that the derived getters are self-consistent.
void _expectGettersConsistent(PreflightResult r) {
  expect(r.isOk, r.level == PreflightLevel.ok);
  expect(r.isBlocked, r.level == PreflightLevel.block);
  expect(r.hasWarnings, r.level == PreflightLevel.warn);

  final trueCount = [r.isOk, r.isBlocked, r.hasWarnings].where((b) => b).length;
  expect(trueCount, 1, reason: 'exactly one level getter must be true');

  if (r.isBlocked) {
    expect(r.blocking, isNotEmpty, reason: 'blocked => blocking non-empty');
  } else {
    expect(r.blocking, isEmpty, reason: 'not blocked => blocking empty');
  }
  for (final b in r.blocking) {
    expect(b.severity, PreflightSeverity.block);
  }
  // fixActions must mirror issues order exactly.
  expect(r.fixActions, r.issues.map((i) => i.fixAction).toList());
}

String _capitalize(String s) =>
    s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

void main() {
  // ---------------------------------------------------------------------------
  // 1. EXHAUSTIVE overall-level truth table, 16 combos x {aggressive, stock}.
  // ---------------------------------------------------------------------------
  group('EXHAUSTIVE 2^4 x OEM => correct overall roll-up level', () {
    for (final f in _allFlagCombos()) {
      test('$f => ${_expectedLevel(f).name} (level is OEM-independent)',
          () async {
        final aggressive = await _run(f, 'xiaomi');
        final stock = await _run(f, 'google');

        expect(aggressive.level, _expectedLevel(f), reason: 'aggressive: $f');
        expect(stock.level, _expectedLevel(f), reason: 'stock: $f');
        // Aggressiveness must not move the overall verdict.
        expect(aggressive.level, stock.level,
            reason: 'OEM must not change overall level for $f');

        expect(aggressive.issues.length, _expectedIssueCount(f),
            reason: 'issue count == count of bad states: $f');
        expect(stock.issues.length, _expectedIssueCount(f),
            reason: 'issue count == count of bad states: $f');

        _expectGettersConsistent(aggressive);
        _expectGettersConsistent(stock);
      });
    }
  });

  // ---------------------------------------------------------------------------
  // 2. EXHAUSTIVE per-issue: presence, severity, fixAction, and copy.
  // ---------------------------------------------------------------------------
  group('EXHAUSTIVE: each present issue has right severity/action/copy', () {
    for (final f in _allFlagCombos()) {
      for (final aggressive in const [true, false]) {
        final oem = aggressive ? 'redmi' : 'google';
        test('$f oem=$oem (aggressive=$aggressive)', () async {
          final r = await _run(f, oem);

          // Presence must exactly track the bad states — nothing extra, nothing
          // silently dropped.
          expect(r.issueOf(PreflightIssueCode.notifications) != null,
              !f.notifications,
              reason: 'notifications issue presence: $f');
          expect(
              r.issueOf(PreflightIssueCode.exactAlarm) != null, !f.exactAlarm,
              reason: 'exact-alarm issue presence: $f');
          expect(r.issueOf(PreflightIssueCode.batteryOptimization) != null,
              !f.batteryExempt,
              reason: 'battery issue presence: $f');
          expect(
              r.issueOf(PreflightIssueCode.preciseLocation) != null, !f.precise,
              reason: 'precise issue presence: $f');

          // Every surfaced issue must carry usable UI payload.
          for (final issue in r.issues) {
            expect(issue.code.trim(), isNotEmpty);
            expect(issue.title.trim(), isNotEmpty,
                reason: 'issue "${issue.code}" title must be non-empty');
            expect(issue.message.trim(), isNotEmpty,
                reason: 'issue "${issue.code}" message must be non-empty');
            expect(issue.message.trim().length, greaterThan(10),
                reason: 'issue "${issue.code}" message must be a real sentence');
            expect(_knownActions, contains(issue.fixAction),
                reason: 'issue "${issue.code}" fixAction must be a known key');
            expect(issue.fixAction, _expectedActionFor(issue.code),
                reason: 'issue "${issue.code}" fixAction must match its code');
          }

          // Severities per the documented contract.
          final notif = r.issueOf(PreflightIssueCode.notifications);
          if (notif != null) {
            expect(notif.severity, PreflightSeverity.block,
                reason: 'notifications-off is always a hard BLOCK');
          }
          final exact = r.issueOf(PreflightIssueCode.exactAlarm);
          if (exact != null) {
            expect(
                exact.severity,
                aggressive
                    ? PreflightSeverity.warn
                    : PreflightSeverity.advisory,
                reason: 'exact-alarm severity sharpens on aggressive OEM');
          }
          final batt = r.issueOf(PreflightIssueCode.batteryOptimization);
          if (batt != null) {
            expect(
                batt.severity,
                aggressive
                    ? PreflightSeverity.warn
                    : PreflightSeverity.advisory,
                reason: 'battery severity sharpens on aggressive OEM');
          }
          final prec = r.issueOf(PreflightIssueCode.preciseLocation);
          if (prec != null) {
            expect(prec.severity, PreflightSeverity.warn,
                reason: 'approximate location is always a warn');
          }
        });
      }
    }
  });

  // ---------------------------------------------------------------------------
  // 3. EXHAUSTIVE ordering: issues most-severe-first for every combo/OEM.
  // ---------------------------------------------------------------------------
  group('EXHAUSTIVE: issues sorted most-severe first', () {
    for (final f in _allFlagCombos()) {
      for (final oem in const ['poco', 'google']) {
        test('$f oem=$oem', () async {
          final r = await _run(f, oem);
          for (var i = 1; i < r.issues.length; i++) {
            // Lower severity index == more severe; must be non-decreasing.
            expect(r.issues[i - 1].severity.index,
                lessThanOrEqualTo(r.issues[i].severity.index),
                reason: 'must be non-decreasing severity index: $f oem=$oem');
          }
          if (r.issues.isNotEmpty) {
            final minIdx = r.issues
                .map((i) => i.severity.index)
                .reduce((a, b) => a < b ? a : b);
            expect(r.issues.first.severity.index, minIdx,
                reason: 'first issue must be the most severe present');
          }
        });
      }
    }
  });

  // ---------------------------------------------------------------------------
  // 4. CARDINAL SIN: notifications OFF => hard BLOCK in EVERY combination.
  //    (An alarm that can never show is the never-fires failure — must block.)
  // ---------------------------------------------------------------------------
  group('CARDINAL SIN: notifications OFF => hard BLOCK, always', () {
    for (final f in _allFlagCombos().where((f) => !f.notifications)) {
      for (final oem in const ['xiaomi', 'google', 'samsung', 'nothing']) {
        test('$f oem=$oem => BLOCK', () async {
          final r = await _run(f, oem);
          expect(r.level, PreflightLevel.block,
              reason: 'notifications-off must block regardless of other state');
          expect(r.isBlocked, isTrue);

          final n = r.issueOf(PreflightIssueCode.notifications);
          expect(n, isNotNull);
          expect(n!.severity, PreflightSeverity.block);
          expect(n.fixAction, PreflightFixAction.openNotificationSettings);

          expect(r.blocking, isNotEmpty);
          // Only the notifications precondition ever yields a block severity.
          for (final b in r.blocking) {
            expect(b.code, PreflightIssueCode.notifications);
          }
          // The block must be ranked first for the UI.
          expect(r.issues.first.code, PreflightIssueCode.notifications);
        });
      }
    }
  });

  // ---------------------------------------------------------------------------
  // 5. CARDINAL SIN: a fire-late risk is NEVER silently dropped.
  // ---------------------------------------------------------------------------
  group('CARDINAL SIN: bad state always surfaces an issue', () {
    test('exact-alarm OFF => an exact_alarm issue in every combo/OEM',
        () async {
      for (final f in _allFlagCombos().where((f) => !f.exactAlarm)) {
        for (final oem in const ['xiaomi', 'google']) {
          final r = await _run(f, oem);
          expect(r.issueOf(PreflightIssueCode.exactAlarm), isNotNull,
              reason: 'exact-alarm risk dropped for $f oem=$oem');
        }
      }
    });

    test('battery not exempt => a battery issue in every combo/OEM', () async {
      for (final f in _allFlagCombos().where((f) => !f.batteryExempt)) {
        for (final oem in const ['oppo', 'google']) {
          final r = await _run(f, oem);
          expect(r.issueOf(PreflightIssueCode.batteryOptimization), isNotNull,
              reason: 'battery risk dropped for $f oem=$oem');
        }
      }
    });

    test('approximate location => a precise issue in every combo/OEM',
        () async {
      for (final f in _allFlagCombos().where((f) => !f.precise)) {
        for (final oem in const ['vivo', 'google']) {
          final r = await _run(f, oem);
          expect(r.issueOf(PreflightIssueCode.preciseLocation), isNotNull,
              reason: 'precise-location risk dropped for $f oem=$oem');
        }
      }
    });
  });

  // ---------------------------------------------------------------------------
  // 6. aggressive OEM + (no exact-alarm OR no battery-exempt) => at least warn,
  //    with the per-issue severity sharpened to warn; stock stays advisory but
  //    STILL rolls up to at-least-warn.
  // ---------------------------------------------------------------------------
  group('aggressive OEM sharpens exact-alarm / battery to WARN', () {
    for (final oem in _indiaMix) {
      test('$oem: exact-alarm OFF => WARN issue + level >= warn', () async {
        final r = await _run(const _Flags(true, false, true, true), oem);
        final i = r.issueOf(PreflightIssueCode.exactAlarm)!;
        expect(i.severity, PreflightSeverity.warn, reason: oem);
        expect(r.level.index, greaterThanOrEqualTo(PreflightLevel.warn.index),
            reason: oem);
      });

      test('$oem: battery not exempt => WARN issue + level >= warn', () async {
        final r = await _run(const _Flags(true, true, false, true), oem);
        final i = r.issueOf(PreflightIssueCode.batteryOptimization)!;
        expect(i.severity, PreflightSeverity.warn, reason: oem);
        expect(r.level.index, greaterThanOrEqualTo(PreflightLevel.warn.index),
            reason: oem);
      });
    }

    for (final oem in _stockOems) {
      test('$oem: exact-alarm OFF => advisory issue but level still warn',
          () async {
        final r = await _run(const _Flags(true, false, true, true), oem);
        final i = r.issueOf(PreflightIssueCode.exactAlarm)!;
        expect(i.severity, PreflightSeverity.advisory, reason: oem);
        // Advisory still rolls up so the rider is warned before arming.
        expect(r.level, PreflightLevel.warn, reason: oem);
      });

      test('$oem: battery not exempt => advisory issue but level still warn',
          () async {
        final r = await _run(const _Flags(true, true, false, true), oem);
        final i = r.issueOf(PreflightIssueCode.batteryOptimization)!;
        expect(i.severity, PreflightSeverity.advisory, reason: oem);
        expect(r.level, PreflightLevel.warn, reason: oem);
      });
    }
  });

  // ---------------------------------------------------------------------------
  // 7. approximate location => at least warn, on every combo/OEM.
  // ---------------------------------------------------------------------------
  group('approximate location => at least warn', () {
    for (final f in _allFlagCombos().where((f) => !f.precise)) {
      for (final oem in const ['xiaomi', 'google']) {
        test('$f oem=$oem => level >= warn', () async {
          final r = await _run(f, oem);
          expect(r.level.index, greaterThanOrEqualTo(PreflightLevel.warn.index),
              reason: 'precise-off must be at least warn: $f oem=$oem');
          expect(r.issueOf(PreflightIssueCode.preciseLocation)!.severity,
              PreflightSeverity.warn);
        });
      }
    }
  });

  // ---------------------------------------------------------------------------
  // 8. All-good => OK; aggressiveness ALONE never creates an issue.
  // ---------------------------------------------------------------------------
  group('all preconditions satisfied => OK', () {
    test('all good + non-aggressive OEM => OK, no issues', () async {
      final r = await _run(const _Flags(true, true, true, true), 'google');
      expect(r.level, PreflightLevel.ok);
      expect(r.isOk, isTrue);
      expect(r.issues, isEmpty);
    });

    test('all good + aggressive OEM => still OK (aggressiveness is not an issue)',
        () async {
      for (final oem in _indiaMix) {
        final r = await _run(const _Flags(true, true, true, true), oem);
        expect(r.level, PreflightLevel.ok, reason: oem);
        expect(r.issues, isEmpty, reason: oem);
      }
    });
  });

  // ---------------------------------------------------------------------------
  // 9. OEM changes per-issue severity of exact/battery but NOT the overall
  //    verdict, nor the set of issue codes, nor notif/precise severities.
  // ---------------------------------------------------------------------------
  group('OEM aggressiveness: severity-only, never the verdict', () {
    for (final f in _allFlagCombos()) {
      test('$f: same level & codes on aggressive vs stock', () async {
        final aggressive = await _run(f, 'vivo');
        final stock = await _run(f, 'google');

        expect(aggressive.level, stock.level, reason: '$f');
        // Order-independent: aggressive vs stock may sort exact/battery
        // differently (warn vs advisory), so compare sorted code lists.
        final aCodes = aggressive.issues.map((i) => i.code).toList()..sort();
        final sCodes = stock.issues.map((i) => i.code).toList()..sort();
        expect(aCodes, sCodes, reason: '$f');

        // Notifications and precise severities are OEM-invariant.
        final an = aggressive.issueOf(PreflightIssueCode.notifications);
        final sn = stock.issueOf(PreflightIssueCode.notifications);
        if (an != null && sn != null) {
          expect(an.severity, sn.severity);
        }
        final ap = aggressive.issueOf(PreflightIssueCode.preciseLocation);
        final sp = stock.issueOf(PreflightIssueCode.preciseLocation);
        if (ap != null && sp != null) {
          expect(ap.severity, sp.severity);
        }
      });
    }
  });

  // ---------------------------------------------------------------------------
  // 10. isAggressiveOem: India mix case-insensitively; rejects stock & empties.
  // ---------------------------------------------------------------------------
  group('isAggressiveOem: India mix vs stock', () {
    test('India mix flagged in lower/upper/mixed/padded/embedded forms', () {
      for (final base in _indiaMix) {
        for (final variant in <String>[
          base,
          base.toUpperCase(),
          _capitalize(base),
          '  $base  ',
          '\t$base\n',
          '$base electronics',
          'brand-$base',
        ]) {
          expect(ReliabilityPreflightService.isAggressiveOem(variant), isTrue,
              reason: '"$variant" must be treated as aggressive');
        }
      }
    });

    test('stock / unknown brands are NOT flagged (any casing)', () {
      for (final oem in <String>[
        'google', 'Google', 'GOOGLE',
        'nothing', 'Nothing', 'NOTHING',
        'motorola', 'Motorola', 'MOTOROLA',
        'pixel', 'fairphone', 'crosscall',
        '', ' ', '   ', '\t', '\n',
      ]) {
        expect(ReliabilityPreflightService.isAggressiveOem(oem), isFalse,
            reason: '"$oem" must NOT be treated as aggressive');
      }
    });

    test('tricky casings iQOO / OnePlus / Redmi', () {
      for (final oem in const [
        'iQOO',
        'IQOO',
        'iqoo',
        'OnePlus',
        'ONEPLUS',
        'OnePlus 12R',
        'Redmi Note 13',
        'POCO X6',
      ]) {
        expect(ReliabilityPreflightService.isAggressiveOem(oem), isTrue,
            reason: '"$oem" must be treated as aggressive');
      }
    });

    test('every declared needle matches itself (lower and upper case)', () {
      for (final needle in ReliabilityPreflightService.aggressiveOemNeedles) {
        expect(ReliabilityPreflightService.isAggressiveOem(needle), isTrue,
            reason: 'needle "$needle" must self-match');
        expect(ReliabilityPreflightService.isAggressiveOem(needle.toUpperCase()),
            isTrue,
            reason: 'needle "$needle" must match upper-cased');
      }
    });
  });

  // ---------------------------------------------------------------------------
  // 11. levelForSeverity mapping is total and correct for all severities.
  // ---------------------------------------------------------------------------
  group('levelForSeverity mapping', () {
    test('block=>block; warn=>warn; advisory=>warn', () {
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

  // ---------------------------------------------------------------------------
  // 12. Result immutability: the UI must not be able to mutate the issue list.
  // ---------------------------------------------------------------------------
  group('result immutability', () {
    test('issues list is unmodifiable', () async {
      final r = await _run(const _Flags(false, false, false, false), 'xiaomi');
      expect(r.issues, hasLength(4));
      expect(() => r.issues.add(r.issues.first), throwsUnsupportedError);
      expect(() => r.issues.clear(), throwsUnsupportedError);
    });
  });
}
