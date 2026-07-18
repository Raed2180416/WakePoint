// lib/services/telemetry/telemetry_service.dart
//
// Privacy-safe, on-device telemetry for the reliability funnels HANDOFF §3 calls
// "not optional" for a wake-alarm: the alarm-outcome funnel (the north star —
// "did the alarm fire on time?"), the reliability funnel (FGS survived vs
// OS-killed, Doze, backstop fired, permission states, broken down by device +
// OEM + Android version), EKF/GPS health, and crashes/ANRs.
//
// Design constraints, on purpose:
//   * NO PII, NO raw coordinates. Events carry station/zone-granular identifiers
//     and coarse durations only, so the same schema doubles as the k-anonymous
//     crowdsourced-calibration feed (HANDOFF §4) without ever holding a
//     trajectory. This is enforced by construction: the typed helpers below
//     never accept a lat/lng.
//   * The CORE (event model + routing + ring buffer) is pure and takes an
//     injectable sink, so every funnel is deterministically unit-testable with
//     an in-memory sink. A file-backed sink is provided for production; a
//     network/Crashlytics/PostHog sink can be added later behind the same
//     interface without touching call sites.
//   * Fail-open: telemetry must NEVER throw into the alarm path. Every public
//     method swallows its own errors.

import 'dart:collection';
import 'dart:convert';

/// Outcome of a fired (or missed) alarm — the north-star metric.
enum AlarmOutcome { onTime, early, late, missed, dismissed, snoozed }

/// Stable event-type tags (kept short; they are the analytics keys).
class TelemetryEventType {
  static const String sessionStart = 'session_start';
  static const String alarmArmed = 'alarm_armed';
  static const String gpsLost = 'gps_lost';
  static const String gpsReacquired = 'gps_reacquired';
  static const String alarmOutcome = 'alarm_outcome';
  static const String reliability = 'reliability';
  static const String ekfHealth = 'ekf_health';
  static const String reachability = 'reachability';
  static const String error = 'error';
}

/// One immutable telemetry event.
class TelemetryEvent {
  final String type;
  final int timestampMs;
  final Map<String, Object?> props;

  const TelemetryEvent({
    required this.type,
    required this.timestampMs,
    required this.props,
  });

  Map<String, Object?> toJson() => {
        't': type,
        'ts': timestampMs,
        // Sanitise non-finite doubles (NaN/Infinity): jsonEncode throws on them,
        // which would break the "telemetry never throws" contract. A caller can
        // legitimately hand us a NaN speed or an Infinity ETA on a bad tick.
        for (final e in props.entries) e.key: _jsonSafe(e.value),
      };

  static Object? _jsonSafe(Object? v) =>
      (v is double && !v.isFinite) ? null : v;

  String toJsonLine() => jsonEncode(toJson());
}

/// Sink interface — where events go. Implementations must not throw.
abstract class TelemetrySink {
  void add(TelemetryEvent event);
}

/// In-memory ring buffer sink (default; also used by tests). Bounded so a long
/// session can never exhaust memory.
class InMemoryTelemetrySink implements TelemetrySink {
  final int capacity;
  final Queue<TelemetryEvent> _buf = Queue<TelemetryEvent>();

  InMemoryTelemetrySink({this.capacity = 2000});

  @override
  void add(TelemetryEvent event) {
    _buf.addLast(event);
    // Guard `isNotEmpty` so a zero/negative capacity can't removeFirst() on an
    // empty queue (which throws) — telemetry must never throw into a caller.
    while (_buf.isNotEmpty && _buf.length > capacity) {
      _buf.removeFirst();
    }
  }

  List<TelemetryEvent> get events => List.unmodifiable(_buf);
  int get length => _buf.length;
  void clear() => _buf.clear();

  /// Count events of a type — handy for tests and simple funnels.
  int countOfType(String type) => _buf.where((e) => e.type == type).length;
}

/// The telemetry facade. Singleton in production; construct directly in tests.
class TelemetryService {
  TelemetryService._();
  static final TelemetryService instance = TelemetryService._();

  /// Monotonic clock injector (defaults to wall clock). Tests pass a fixed one
  /// so timestamps are deterministic.
  int Function() nowMs = () => DateTime.now().millisecondsSinceEpoch;

  /// Stable, non-PII device context attached to every event once known.
  Map<String, Object?> _deviceContext = const {};

  final List<TelemetrySink> _sinks = <TelemetrySink>[InMemoryTelemetrySink()];
  bool _enabled = true;

  /// Replace/register sinks. The in-memory sink is kept unless [replace] is set.
  void configure({
    List<TelemetrySink>? sinks,
    bool replace = false,
    bool? enabled,
  }) {
    if (enabled != null) _enabled = enabled;
    if (sinks != null) {
      if (replace) _sinks.clear();
      _sinks.addAll(sinks);
    }
  }

  /// Convenience accessor for the default in-memory sink (for tests / debug UI).
  InMemoryTelemetrySink? get memorySink =>
      _sinks.whereType<InMemoryTelemetrySink>().isEmpty
          ? null
          : _sinks.whereType<InMemoryTelemetrySink>().first;

  void _emit(String type, Map<String, Object?> props) {
    if (!_enabled) return;
    try {
      final ev = TelemetryEvent(
        type: type,
        timestampMs: nowMs(),
        props: {..._deviceContext, ...props},
      );
      for (final s in _sinks) {
        try {
          s.add(ev);
        } catch (_) {/* a bad sink must not break others or the caller */}
      }
    } catch (_) {/* telemetry must never throw into the alarm path */}
  }

  // ---- Funnel entrypoints (typed; PII-free by construction) ----------------

  /// Attach device/OEM/version context to every subsequent event. This is the
  /// per-device breakdown HANDOFF §3 requires to learn which phones fail.
  void setDeviceContext({
    String? manufacturer,
    String? model,
    int? androidSdkInt,
    String? appVersion,
    String? platform,
  }) {
    _deviceContext = {
      if (manufacturer != null) 'oem': manufacturer,
      if (model != null) 'model': model,
      if (androidSdkInt != null) 'sdk': androidSdkInt,
      if (appVersion != null) 'app': appVersion,
      if (platform != null) 'plat': platform,
    };
  }

  void sessionStart({
    bool? locationPrecise,
    bool? notificationsEnabled,
    bool? exactAlarmAllowed,
    bool? batteryOptExempt,
  }) =>
      _emit(TelemetryEventType.sessionStart, {
        if (locationPrecise != null) 'loc_precise': locationPrecise,
        if (notificationsEnabled != null) 'notif': notificationsEnabled,
        if (exactAlarmAllowed != null) 'exact_alarm': exactAlarmAllowed,
        if (batteryOptExempt != null) 'batt_exempt': batteryOptExempt,
      });

  void alarmArmed({required String mode, required num value, String? city, String? line}) =>
      _emit(TelemetryEventType.alarmArmed, {
        'mode': mode,
        'value': value,
        if (city != null) 'city': city,
        if (line != null) 'line': line,
      });

  void gpsLost({required double sinceLastFixSeconds}) =>
      _emit(TelemetryEventType.gpsLost,
          {'since_fix_s': _round(sinceLastFixSeconds)});

  void gpsReacquired({required double blackoutSeconds, double? driftMeters}) =>
      _emit(TelemetryEventType.gpsReacquired, {
        'blackout_s': _round(blackoutSeconds),
        if (driftMeters != null) 'drift_m': _round(driftMeters),
      });

  /// The north-star event. [marginSeconds] > 0 = fired early (safe),
  /// < 0 = fired late (product death). Classify with [classifyOutcome].
  void alarmOutcome({
    required AlarmOutcome outcome,
    double? marginSeconds,
    double? gpsLostSeconds,
    bool? firedViaBackstop,
    bool? firedViaReachability,
    String? mode,
  }) =>
      _emit(TelemetryEventType.alarmOutcome, {
        'outcome': outcome.name,
        if (marginSeconds != null) 'margin_s': _round(marginSeconds),
        if (gpsLostSeconds != null) 'gps_lost_s': _round(gpsLostSeconds),
        if (firedViaBackstop != null) 'backstop': firedViaBackstop,
        if (firedViaReachability != null) 'reach': firedViaReachability,
        if (mode != null) 'mode': mode,
      });

  void reliability({
    bool? fgsSurvived,
    bool? osKilled,
    bool? dozeEntered,
    bool? backstopFired,
  }) =>
      _emit(TelemetryEventType.reliability, {
        if (fgsSurvived != null) 'fgs_survived': fgsSurvived,
        if (osKilled != null) 'os_killed': osKilled,
        if (dozeEntered != null) 'doze': dozeEntered,
        if (backstopFired != null) 'backstop_fired': backstopFired,
      });

  void reachabilityActivated({
    required double dtSeconds,
    required double boundMeters,
    required double deadReckonedMeters,
    bool? watchdog,
  }) =>
      _emit(TelemetryEventType.reachability, {
        'dt_s': _round(dtSeconds),
        'bound_m': _round(boundMeters),
        'dr_m': _round(deadReckonedMeters),
        if (watchdog != null) 'watchdog': watchdog,
      });

  void ekfHealth({double? sigmaSMeters, double? sigmaVMps, bool? coldStart, int? phantomRejections}) =>
      _emit(TelemetryEventType.ekfHealth, {
        if (sigmaSMeters != null) 'sigma_s': _round(sigmaSMeters),
        if (sigmaVMps != null) 'sigma_v': _round(sigmaVMps),
        if (coldStart != null) 'cold_start': coldStart,
        if (phantomRejections != null) 'phantom_rej': phantomRejections,
      });

  /// Crash / non-fatal handler sink. Stack is truncated; message is scrubbed of
  /// obvious file paths to avoid leaking usernames.
  void recordError(Object error, StackTrace? stack, {bool fatal = false}) =>
      _emit(TelemetryEventType.error, {
        'fatal': fatal,
        'err': _scrub(error.toString(), 300),
        if (stack != null) 'stack': _scrub(stack.toString(), 1200),
      });

  // ---- Helpers -------------------------------------------------------------

  static double _round(double v) =>
      v.isFinite ? (v * 10).roundToDouble() / 10 : 0.0;

  static String _scrub(String s, int max) {
    // Drop absolute home paths that could carry a username.
    var out = s.replaceAll(RegExp(r'/(home|Users)/[^/\s]+'), '/~');
    if (out.length > max) out = out.substring(0, max);
    return out;
  }

  /// Classify a fire margin into an outcome. margin = fireTime - trueArrival
  /// expressed as (trueArrival - fireTime) seconds of lead: positive => early.
  static AlarmOutcome classifyOutcome(double leadSeconds,
      {double onTimeWindow = 30.0}) {
    if (leadSeconds < 0) return AlarmOutcome.late;
    if (leadSeconds <= onTimeWindow) return AlarmOutcome.onTime;
    return AlarmOutcome.early;
  }
}
