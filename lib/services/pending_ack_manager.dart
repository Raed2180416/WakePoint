// lib/services/pending_ack_manager.dart
//
// ============================================================================
// PENDING ACK MANAGER - Reliable IPC acknowledgment handling
// ============================================================================
//
// Problem: The _pendingAcks map in TrackingService can have completers that
// never complete, causing memory leaks and potential deadlocks.
//
// Solution: This manager adds:
// 1. Timeout-based cleanup (10 seconds default)
// 2. Proper disposal of pending completers
// 3. Error handling for timeouts
//
// ============================================================================

import 'dart:async';

/// Exception thrown when an IPC acknowledgment times out.
class AckTimeoutException implements Exception {
  final String requestId;
  final Duration timeout;

  AckTimeoutException(this.requestId, this.timeout);

  @override
  String toString() =>
      'AckTimeoutException: ACK timeout for request $requestId after ${timeout.inSeconds}s';
}

/// Manages pending IPC acknowledgments with timeout-based cleanup.
///
/// Usage:
/// ```dart
/// final manager = PendingAckManager();
///
/// // When sending a message that expects an ACK
/// final requestId = 'req_123';
/// try {
///   // Send the message
///   service.invoke('startTracking', {'requestId': requestId, ...});
///   // Wait for acknowledgment
///   await manager.waitForAck(requestId);
///   print('ACK received');
/// } on AckTimeoutException {
///   print('ACK timeout - retry or handle failure');
/// }
///
/// // When receiving an ACK
/// manager.receiveAck(requestId);
///
/// // On dispose
/// manager.dispose();
/// ```
class PendingAckManager {
  /// Default timeout for acknowledgments.
  static const Duration defaultTimeout = Duration(seconds: 10);

  /// Map of pending acknowledgments.
  final Map<String, _PendingAck> _pending = {};

  /// Current timeout setting.
  final Duration timeout;

  /// Create a new manager with optional custom timeout.
  PendingAckManager({this.timeout = defaultTimeout});

  /// Wait for an acknowledgment with the given request ID.
  ///
  /// Throws [AckTimeoutException] if the ACK is not received within [timeout].
  Future<void> waitForAck(String requestId) {
    final completer = Completer<void>();

    final timeoutTimer = Timer(timeout, () {
      if (!completer.isCompleted) {
        _pending.remove(requestId);
        completer.completeError(AckTimeoutException(requestId, timeout));
      }
    });

    _pending[requestId] = _PendingAck(completer, timeoutTimer);
    return completer.future;
  }

  /// Receive an acknowledgment for the given request ID.
  ///
  /// Cancels the timeout timer and completes the waiting future.
  void receiveAck(String requestId) {
    final pending = _pending.remove(requestId);
    if (pending != null) {
      pending.timeoutTimer.cancel();
      if (!pending.completer.isCompleted) {
        pending.completer.complete();
      }
    }
  }

  /// Check if there are any pending acknowledgments.
  bool get hasPending => _pending.isNotEmpty;

  /// Get the number of pending acknowledgments.
  int get pendingCount => _pending.length;

  /// Cancel a specific pending acknowledgment without completing it.
  void cancel(String requestId) {
    final pending = _pending.remove(requestId);
    if (pending != null) {
      pending.timeoutTimer.cancel();
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(
          StateError('ACK cancelled for request $requestId'),
        );
      }
    }
  }

  /// Dispose all pending acknowledgments.
  ///
  /// Cancels all timers and completes all completers with errors.
  void dispose() {
    for (final entry in _pending.entries) {
      entry.value.timeoutTimer.cancel();
      if (!entry.value.completer.isCompleted) {
        entry.value.completer.completeError(
          StateError(
            'PendingAckManager disposed while waiting for ${entry.key}',
          ),
        );
      }
    }
    _pending.clear();
  }
}

/// Internal class to hold pending acknowledgment state.
class _PendingAck {
  final Completer<void> completer;
  final Timer timeoutTimer;

  _PendingAck(this.completer, this.timeoutTimer);
}
