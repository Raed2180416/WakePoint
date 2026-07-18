// lib/services/reliability/reliability_preflight_service.dart
//
// ARM-TIME RELIABILITY PREFLIGHT (HANDOFF §1 P1.3, §3).
//
// Before a rider arms the alarm for a critical commute, GeoWake must know
// whether THIS phone can actually wake them. Nothing in the app currently READS
// the OS states that decide that outcome before arming. This service does, and
// turns them into a verdict the arming UI can act on:
//
//   * areNotificationsEnabled()        — if OFF, the alarm literally cannot be
//                                        shown. Hard BLOCK: do not let a rider
//                                        trust an alarm that can never appear.
//   * canScheduleExactAlarms()         — if OFF, the exact-alarm backstop can be
//                                        held back by the OS and fire late.
//   * isIgnoringBatteryOptimizations() — if the app is NOT exempt, an aggressive
//                                        OEM ROM (MIUI/HyperOS, ColorOS,
//                                        Funtouch, EMUI, One UI) can kill the
//                                        background service mid-trip.
//   * precise-vs-approximate location  — approximate-only makes the near-stop
//                                        geometry fuzzy, so the alarm can be off.
//
// DESIGN, on purpose:
//   * The CORE is PURE and headless-testable. It reads the OS states through an
//     injected [ReliabilityProbe], NEVER a real plugin — so every permission
//     combination is a deterministic unit test via [FakeReliabilityProbe]. The
//     concrete probe (permission_handler + device_info_plus) is wired at
//     integration, outside this file.
//   * Every issue carries a plain-English, jargon-free user message and a stable
//     [PreflightIssue.fixAction] key the UI maps to the correct settings
//     deep-link (reusing OemAutostartService for the OEM screens). This service
//     never opens a screen itself.
//   * OEM aggressiveness (dontkillmyapp 5/5 + the India device mix) sharpens the
//     severity of the exact-alarm and battery warnings, because on a ROM that
//     kills background work those states are far more likely to cost a rider
//     their stop. [isAggressiveOem] is a pure substring test that mirrors
//     OemAutostartService's manufacturer matching without importing its
//     platform-coupled plugins.

/// Overall arm-time verdict.
///
/// Ordered least→most severe so the roll-up can compare by [index].
enum PreflightLevel {
  /// Every reliability precondition is satisfied.
  ok,

  /// The alarm can still work, but this phone is at real risk — the UI should
  /// surface the issues and offer to fix them before arming.
  warn,

  /// The alarm physically cannot fire (notifications off). The UI must block
  /// arming until it is resolved.
  block,
}

/// Per-issue severity, ordered most→least severe so [PreflightResult.issues]
/// can be sorted by [index]. The overall [PreflightLevel] is the roll-up of the
/// worst issue via [ReliabilityPreflightService.levelForSeverity].
enum PreflightSeverity {
  /// Alarm cannot fire — rolls up to [PreflightLevel.block].
  block,

  /// Strong warning: on this device the alarm is at real risk. Rolls up to
  /// [PreflightLevel.warn].
  warn,

  /// Advisory: worth improving, but the alarm should still work. Rolls up to
  /// [PreflightLevel.warn].
  advisory,
}

/// Stable machine keys identifying which precondition an issue is about. Kept
/// short and stable — they double as telemetry/analytics keys (HANDOFF §3).
class PreflightIssueCode {
  static const String notifications = 'notifications';
  static const String exactAlarm = 'exact_alarm';
  static const String batteryOptimization = 'battery_optimization';
  static const String preciseLocation = 'precise_location';
}

/// Stable action keys the UI maps to the correct settings deep-link. The core
/// only names the action; opening the screen is the integration layer's job
/// (OemAutostartService for OEM screens, app_settings for the OS ones).
class PreflightFixAction {
  static const String openNotificationSettings = 'openNotificationSettings';
  static const String openExactAlarmSettings = 'openExactAlarmSettings';
  static const String openBatteryOptimizationSettings =
      'openBatteryOptimizationSettings';
  static const String openLocationSettings = 'openLocationSettings';
}

/// One thing wrong (or worth improving) about this phone's ability to wake the
/// rider. [message] and [title] are user-facing and jargon-free.
class PreflightIssue {
  /// Stable identifier for this precondition (see [PreflightIssueCode]).
  final String code;

  /// How badly this hurts reliability on THIS device.
  final PreflightSeverity severity;

  /// Short, plain-English headline for the UI.
  final String title;

  /// Plain-English explanation of the risk and the fix. No technical jargon.
  final String message;

  /// Stable key the UI maps to the settings screen that fixes this (see
  /// [PreflightFixAction]).
  final String fixAction;

  const PreflightIssue({
    required this.code,
    required this.severity,
    required this.title,
    required this.message,
    required this.fixAction,
  });

  @override
  String toString() => 'PreflightIssue($code, ${severity.name}, $fixAction)';
}

/// The outcome of a preflight check: an overall [level] plus the individual
/// [issues], sorted most-severe first.
class PreflightResult {
  final PreflightLevel level;
  final List<PreflightIssue> issues;

  const PreflightResult({required this.level, required this.issues});

  bool get isOk => level == PreflightLevel.ok;
  bool get isBlocked => level == PreflightLevel.block;
  bool get hasWarnings => level == PreflightLevel.warn;

  /// The blocking issues (alarm cannot fire). Non-empty iff [isBlocked].
  List<PreflightIssue> get blocking =>
      issues.where((i) => i.severity == PreflightSeverity.block).toList();

  /// The fix-action keys for every issue, most-severe first — handy for the UI
  /// to render one "Fix" button per problem.
  List<String> get fixActions => issues.map((i) => i.fixAction).toList();

  /// The issue for [code], or null if that precondition passed.
  PreflightIssue? issueOf(String code) {
    for (final i in issues) {
      if (i.code == code) return i;
    }
    return null;
  }

  @override
  String toString() =>
      'PreflightResult(${level.name}, ${issues.length} issue(s))';
}

/// The OS states this service reads, abstracted so the core never touches a real
/// plugin. The concrete implementation (permission_handler + device_info_plus)
/// is wired at integration; tests use [FakeReliabilityProbe].
abstract class ReliabilityProbe {
  /// canScheduleExactAlarms(): can the app schedule an exact (precise-time)
  /// alarm? Treated as `true` on platforms/versions where it does not apply.
  Future<bool> get exactAlarmAllowed;

  /// isIgnoringBatteryOptimizations(): is the app exempt from Doze/battery
  /// restrictions so its background service survives?
  Future<bool> get batteryOptExempt;

  /// areNotificationsEnabled(): can the app post the notification that IS the
  /// alarm?
  Future<bool> get notificationsEnabled;

  /// Is precise (fine) location granted, as opposed to approximate-only?
  Future<bool> get preciseLocation;

  /// Lower-cased device manufacturer (e.g. `xiaomi`), or `''` when unknown/off
  /// Android.
  Future<String> get manufacturer;
}

/// In-memory probe for tests: all-good by default with a non-aggressive OEM, so
/// the "all good => OK" path is a one-liner and each field is flipped
/// independently to exercise a combination.
class FakeReliabilityProbe implements ReliabilityProbe {
  bool exactAlarm;
  bool batteryExempt;
  bool notifications;
  bool precise;
  String oem;

  FakeReliabilityProbe({
    this.exactAlarm = true,
    this.batteryExempt = true,
    this.notifications = true,
    this.precise = true,
    this.oem = 'google',
  });

  @override
  Future<bool> get exactAlarmAllowed async => exactAlarm;

  @override
  Future<bool> get batteryOptExempt async => batteryExempt;

  @override
  Future<bool> get notificationsEnabled async => notifications;

  @override
  Future<bool> get preciseLocation async => precise;

  @override
  Future<String> get manufacturer async => oem;
}

/// Turns raw OS reliability states into an arm-time verdict.
///
/// Pure and injectable: construct with any [ReliabilityProbe]. [check] is the
/// single entry point.
class ReliabilityPreflightService {
  final ReliabilityProbe probe;

  ReliabilityPreflightService(this.probe);

  /// Manufacturer substrings for ROMs known to aggressively kill background work
  /// (dontkillmyapp "5/5" offenders plus the India device mix from HANDOFF §1).
  /// Matched as a lower-cased substring, mirroring OemAutostartService so the two
  /// stay in sync without this pure module importing its platform plugins.
  static const List<String> aggressiveOemNeedles = <String>[
    // Xiaomi family — MIUI / HyperOS
    'xiaomi', 'redmi', 'poco', 'blackshark',
    // Oppo family — ColorOS / OxygenOS (oplus)
    'oppo', 'realme', 'oneplus',
    // Vivo family — Funtouch / OriginOS
    'vivo', 'iqoo',
    // Huawei family — EMUI / MagicOS
    'huawei', 'honor',
    // Samsung — One UI (device care)
    'samsung',
    // Other dontkillmyapp 5/5 offenders
    'meizu', 'asus', 'lenovo', 'wiko', 'nokia', 'hmd', 'sony',
    'letv', 'leeco', 'unihertz', 'blackview',
    // Transsion — dominant in the India/Africa budget tier, aggressive PM
    'tecno', 'infinix', 'itel',
  ];

  /// True if [manufacturer] belongs to an OEM known to kill background apps.
  /// Case-insensitive, substring-based, empty-safe.
  static bool isAggressiveOem(String manufacturer) {
    final m = manufacturer.trim().toLowerCase();
    if (m.isEmpty) return false;
    return aggressiveOemNeedles.any(m.contains);
  }

  /// The overall level a single issue of [severity] rolls up to.
  static PreflightLevel levelForSeverity(PreflightSeverity severity) {
    switch (severity) {
      case PreflightSeverity.block:
        return PreflightLevel.block;
      case PreflightSeverity.warn:
      case PreflightSeverity.advisory:
        return PreflightLevel.warn;
    }
  }

  /// Read the OS states through the probe and produce the arm-time verdict.
  Future<PreflightResult> check() async {
    final bool notifications = await probe.notificationsEnabled;
    final bool exactAlarm = await probe.exactAlarmAllowed;
    final bool batteryExempt = await probe.batteryOptExempt;
    final bool precise = await probe.preciseLocation;
    final String manufacturer = await probe.manufacturer;
    final bool aggressive = isAggressiveOem(manufacturer);

    final issues = <PreflightIssue>[];

    // Notifications OFF => the alarm can never appear. Hard block.
    if (!notifications) {
      issues.add(const PreflightIssue(
        code: PreflightIssueCode.notifications,
        severity: PreflightSeverity.block,
        title: 'Turn on notifications',
        message:
            "GeoWake can't wake you while notifications are turned off. Turn "
            'them on so its alarm can reach you.',
        fixAction: PreflightFixAction.openNotificationSettings,
      ));
    }

    // Exact-alarm backstop: a missing precise-alarm right can let the backup
    // alarm fire late. It bites hardest on ROMs that already meddle with timing.
    if (!exactAlarm) {
      final bool strong = aggressive;
      issues.add(PreflightIssue(
        code: PreflightIssueCode.exactAlarm,
        severity: strong ? PreflightSeverity.warn : PreflightSeverity.advisory,
        title: 'Allow alarms & reminders',
        message: strong
            ? 'Your phone can hold back timed alarms, so the backup alarm might '
                'go off late. Turn on "Alarms & reminders" for GeoWake so it '
                'wakes you right on time.'
            : 'Turning on "Alarms & reminders" for GeoWake keeps its backup '
                'alarm from going off a little late.',
        fixAction: PreflightFixAction.openExactAlarmSettings,
      ));
    }

    // Battery restriction: on an aggressive OEM this is the #1 cause of a missed
    // wake-up, so it is a strong warning there and a gentle advisory elsewhere.
    if (!batteryExempt) {
      issues.add(PreflightIssue(
        code: PreflightIssueCode.batteryOptimization,
        severity:
            aggressive ? PreflightSeverity.warn : PreflightSeverity.advisory,
        title: 'Keep GeoWake running',
        message: aggressive
            ? "Your phone's battery saver can close GeoWake while it's in your "
                'pocket and stop the alarm. Let it keep running so it can wake '
                'you.'
            : 'Letting GeoWake keep running in the background makes the alarm '
                'more dependable when your screen is off.',
        fixAction: PreflightFixAction.openBatteryOptimizationSettings,
      ));
    }

    // Approximate-only location makes the near-stop geometry fuzzy.
    if (!precise) {
      issues.add(const PreflightIssue(
        code: PreflightIssueCode.preciseLocation,
        severity: PreflightSeverity.warn,
        title: 'Turn on precise location',
        message:
            "With only approximate location, GeoWake can't tell exactly when "
            'you reach your stop, so the alarm may be off. Turn on precise '
            'location for an accurate alarm.',
        fixAction: PreflightFixAction.openLocationSettings,
      ));
    }

    // Most-severe first (block, then warn, then advisory).
    issues.sort((a, b) => a.severity.index.compareTo(b.severity.index));

    return PreflightResult(
      level: _rollUp(issues),
      issues: List.unmodifiable(issues),
    );
  }

  static PreflightLevel _rollUp(List<PreflightIssue> issues) {
    var level = PreflightLevel.ok;
    for (final issue in issues) {
      final l = levelForSeverity(issue.severity);
      if (l.index > level.index) level = l;
    }
    return level;
  }
}
