// test/pending_ack_manager_test.dart
//
// Unit tests for PendingAckManager - IPC acknowledgment handling with timeouts.

import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/pending_ack_manager.dart';

void main() {
  group('PendingAckManager', () {
    late PendingAckManager manager;

    setUp(() {
      manager = PendingAckManager(timeout: const Duration(milliseconds: 100));
    });

    tearDown(() {
      manager.dispose();
    });

    test('receiveAck completes waiting future', () async {
      final requestId = 'test_1';

      // Start waiting in the background
      final future = manager.waitForAck(requestId);

      // Simulate receiving ACK
      manager.receiveAck(requestId);

      // Should complete without throwing
      await expectLater(future, completes);
    });

    test('timeout throws AckTimeoutException', () async {
      final requestId = 'test_timeout';

      // Wait for ACK that never comes
      final future = manager.waitForAck(requestId);

      // Should throw timeout exception
      await expectLater(future, throwsA(isA<AckTimeoutException>()));
    });

    test('pendingCount tracks pending acks', () async {
      // Use a separate manager for this test to avoid tearDown issues
      final localManager = PendingAckManager(
        timeout: const Duration(milliseconds: 100),
      );

      expect(localManager.pendingCount, equals(0));

      // Add some pending acks
      // ignore: unawaited_futures
      localManager.waitForAck('req_1');
      expect(localManager.pendingCount, equals(1));

      // ignore: unawaited_futures
      localManager
          .waitForAck('req_2')
          .catchError((_) {}); // Ignore error on dispose
      expect(localManager.pendingCount, equals(2));

      // Receive one
      localManager.receiveAck('req_1');
      expect(localManager.pendingCount, equals(1));

      // Clean up to avoid dangling timers
      localManager.dispose();
    });

    test('cancel removes pending ack with error', () async {
      final requestId = 'test_cancel';

      final future = manager.waitForAck(requestId);
      manager.cancel(requestId);

      await expectLater(future, throwsA(isA<StateError>()));
      expect(manager.pendingCount, equals(0));
    });

    test('dispose cancels all pending acks', () async {
      // Add multiple pending acks
      final futures = [
        manager.waitForAck('req_1'),
        manager.waitForAck('req_2'),
        manager.waitForAck('req_3'),
      ];

      manager.dispose();

      // All should complete with errors
      for (final future in futures) {
        await expectLater(future, throwsA(isA<StateError>()));
      }
    });

    test('hasPending returns correct value', () {
      expect(manager.hasPending, isFalse);

      // ignore: unawaited_futures
      manager.waitForAck('req_1');
      expect(manager.hasPending, isTrue);

      manager.receiveAck('req_1');
      expect(manager.hasPending, isFalse);
    });

    test('receiving ack for unknown request is no-op', () {
      // Should not throw
      expect(() => manager.receiveAck('unknown_request'), returnsNormally);
    });

    test('receiving ack twice is safe', () async {
      final requestId = 'test_double_ack';

      final future = manager.waitForAck(requestId);
      manager.receiveAck(requestId);
      manager.receiveAck(requestId); // Second ack should be no-op

      await expectLater(future, completes);
    });
  });

  group('AckTimeoutException', () {
    test('toString contains request ID and timeout', () {
      final exception = AckTimeoutException(
        'test_request',
        const Duration(seconds: 10),
      );

      expect(exception.toString(), contains('test_request'));
      expect(exception.toString(), contains('10'));
    });
  });
}
