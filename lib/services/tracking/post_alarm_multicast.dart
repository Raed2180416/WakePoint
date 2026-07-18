// lib/services/tracking/post_alarm_multicast.dart
//
// POST-ALARM multicast — the ONE safe hook additive features (Guardian mode,
// "arrived safely" push, analytics) may use to observe an alarm firing WITHOUT
// ever being able to delay, reorder, or abort the wake.
//
// WHY THIS EXISTS (core-safety, FEATURES_SPEC §3.3 "SILENT MISSED WAKE"):
//   AlarmController.onDestinationAlarmFired is a single unguarded callback
//   invoked SYNCHRONOUSLY inside setDestinationAlarmFiredForKey, BEFORE the
//   wake notification dispatches, at a point where the fired-flag is already
//   latched true. A listener that throws there leaves a permanent silent
//   no-wake. Features MUST NOT hang off that callback.
//
//   Instead they register here. [dispatch] is called from the END of
//   AlarmController.triggerAlarmNotification — AFTER the notification /
//   audio / vibration have already been raised — and every listener is:
//     • fired on its own microtask (never on the caller's critical path), and
//     • wrapped in its own try/catch,
//   so a synchronous throw OR an async hang in any listener can neither delay
//   nor abort the ring, and one bad listener never starves the others.
//
// Contract for listeners: be fire-and-forget. Kick network / Hive / push work
// off with `unawaited(...)`; never block synchronously. The multicast will not
// await you and does not observe your result.

import 'dart:async';
import 'dart:developer' as dev;

/// A listener notified once, immediately after an alarm has been raised.
typedef PostAlarmListener = void Function();

/// Fire-and-forget multicast for post-alarm observers. Process-global singleton
/// so both the UI isolate and the background (wake) isolate can register.
class PostAlarmMulticast {
  PostAlarmMulticast._();
  static final PostAlarmMulticast instance = PostAlarmMulticast._();

  final List<PostAlarmListener> _listeners = <PostAlarmListener>[];

  /// Register [listener]. Idempotent — the same function is not added twice.
  void addListener(PostAlarmListener listener) {
    if (!_listeners.contains(listener)) _listeners.add(listener);
  }

  /// Remove a previously-registered [listener]. Safe if absent.
  void removeListener(PostAlarmListener listener) {
    _listeners.remove(listener);
  }

  /// Number of registered listeners (diagnostics / tests).
  int get listenerCount => _listeners.length;

  /// Drop all listeners (tests).
  void clear() => _listeners.clear();

  /// Notify every listener. Returns SYNCHRONOUSLY and never throws — each
  /// listener runs on its own microtask inside its own guard, so this call is
  /// safe to place at the tail of the alarm dispatch path.
  void dispatch() {
    // Snapshot so a listener that (un)registers during dispatch can't mutate
    // the list we're iterating.
    final snapshot = List<PostAlarmListener>.of(_listeners);
    for (final listener in snapshot) {
      scheduleMicrotask(() {
        try {
          listener();
        } catch (e) {
          // A post-alarm listener failing is never allowed to matter.
          dev.log('post-alarm listener threw (ignored): $e',
              name: 'PostAlarmMulticast');
        }
      });
    }
  }
}
