// Unit tests for EKF logger ring buffer (§12).

import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/core/ekf/ekf_logger.dart';
import 'package:geowake2/core/ekf/ekf_types.dart';

void main() {
  group('EkfLogEntry', () {
    test('headerLine contains expected columns', () {
      final header = EkfLogEntry.headerLine();
      expect(header, contains('monotonic_ms'));
      expect(header, contains('wall_clock_ms'));
      expect(header, contains('imu_ax'));
      expect(header, contains('ekf_s'));
      expect(header, contains('sigma_s'));
      expect(header, contains('gps_lat'));
      expect(header, contains('zupt_event'));
      expect(header, contains('motion_state'));
      expect(header, contains('mode'));
    });

    test('toCsvLine produces comma-separated values', () {
      final entry = EkfLogEntry(
        monotonicMs: 1000,
        wallClockMs: 1705400000000,
        imuAx: 0.123456,
        imuAy: 0.234567,
        imuAz: 9.81,
        ekfS: 500.5,
        sigmaS: 25.0,
        motionState: 'vehicle',
        mode: 'metro',
      );
      final line = entry.toCsvLine();
      final parts = line.split(',');
      expect(parts[0], '1000'); // monotonic_ms
      expect(parts[1], '1705400000000'); // wall_clock_ms
      expect(parts[2], '0.123456'); // imu_ax
      expect(parts[14], '500.500000'); // ekf_s
      expect(parts[17], '25.000000'); // sigma_s
      expect(parts[24], 'vehicle'); // motion_state
      expect(parts[27], 'metro'); // mode
    });

    test('toCsvLine handles null values as empty strings', () {
      final entry = EkfLogEntry(
        monotonicMs: 0,
        wallClockMs: 0,
      );
      final line = entry.toCsvLine();
      final parts = line.split(',');
      // All fields except first two should be empty
      expect(parts[2], ''); // imu_ax
      expect(parts[14], ''); // ekf_s
      expect(parts[24], ''); // motion_state
    });

    test('toCsvLine handles NaN and Infinity as empty', () {
      final entry = EkfLogEntry(
        monotonicMs: 0,
        wallClockMs: 0,
        imuAx: double.nan,
        imuAy: double.infinity,
        imuAz: double.negativeInfinity,
      );
      final line = entry.toCsvLine();
      final parts = line.split(',');
      expect(parts[2], ''); // imu_ax (NaN)
      expect(parts[3], ''); // imu_ay (Infinity)
      expect(parts[4], ''); // imu_az (-Infinity)
    });
  });

  group('EkfLogger', () {
    late EkfLogger logger;

    setUp(() {
      logger = EkfLogger(maxSizeBytes: 1000);
    });

    test('starts inactive', () {
      expect(logger.isActive, isFalse);
      expect(logger.entryCount, 0);
      expect(logger.bufferSizeBytes, 0);
    });

    test('log is ignored when session not active', () {
      logger.log(EkfLogEntry(monotonicMs: 0, wallClockMs: 0));
      expect(logger.entryCount, 0);
    });

    test('log is ignored when disabled', () async {
      await logger.startSession();
      logger.enabled = false;
      logger.log(EkfLogEntry(monotonicMs: 0, wallClockMs: 0));
      expect(logger.entryCount, 0);
      await logger.endSession();
    });

    test('startSession activates logging', () async {
      await logger.startSession();
      expect(logger.isActive, isTrue);
      await logger.endSession();
    });

    test('log adds entries to buffer', () async {
      await logger.startSession();
      logger.log(EkfLogEntry(monotonicMs: 0, wallClockMs: 0));
      expect(logger.entryCount, 1);
      expect(logger.bufferSizeBytes, greaterThan(0));
      await logger.endSession();
    });

    test('logImu creates valid entry', () async {
      await logger.startSession();
      logger.logImu(
        timestamp: const Duration(milliseconds: 100),
        ax: 0.1,
        ay: 0.2,
        az: 9.8,
        gx: 0.01,
        gy: 0.02,
        gz: 0.03,
        gravity: [0.0, 0.0, 1.0],
        motionState: 'vehicle',
        mode: EkfMode.metro,
      );
      expect(logger.entryCount, 1);
      await logger.endSession();
    });

    test('logGps creates valid entry', () async {
      await logger.startSession();
      logger.logGps(
        timestamp: const Duration(milliseconds: 200),
        lat: 12.9716,
        lng: 77.5946,
        accuracy: 15.0,
        innovation: 50.0,
        innovationSigma: 2.5,
      );
      expect(logger.entryCount, 1);
      await logger.endSession();
    });

    test('logZupt creates valid entry', () async {
      await logger.startSession();
      logger.logZupt(
        timestamp: const Duration(milliseconds: 300),
        confirmed: true,
        dwellSeconds: 5.5,
        stationSnapIndex: 3,
      );
      expect(logger.entryCount, 1);
      await logger.endSession();
    });

    test('ring buffer prunes oldest half when exceeding limit', () async {
      // Small buffer limit for testing
      final smallLogger = EkfLogger(maxSizeBytes: 200);
      await smallLogger.startSession();

      // Add entries until we exceed buffer
      for (int i = 0; i < 20; i++) {
        smallLogger.log(EkfLogEntry(
          monotonicMs: i * 100,
          wallClockMs: 1705400000000 + i,
          imuAx: 0.1,
          imuAy: 0.2,
          imuAz: 9.8,
        ));
      }

      // Should have pruned, keeping newest entries
      expect(smallLogger.entryCount, lessThan(20));
      expect(smallLogger.bufferSizeBytes, lessThanOrEqualTo(200));

      await smallLogger.endSession();
    });

    test('endSession clears buffer', () async {
      await logger.startSession();
      logger.log(EkfLogEntry(monotonicMs: 0, wallClockMs: 0));
      await logger.endSession();

      expect(logger.isActive, isFalse);
      expect(logger.entryCount, 0);
      expect(logger.bufferSizeBytes, 0);
    });

    test('flush clears buffer but keeps session active', () async {
      await logger.startSession();
      logger.log(EkfLogEntry(monotonicMs: 0, wallClockMs: 0));
      await logger.flush();

      expect(logger.isActive, isTrue);
      expect(logger.entryCount, 0);
      expect(logger.bufferSizeBytes, 0);

      await logger.endSession();
    });

    test('multiple sessions work independently', () async {
      await logger.startSession();
      logger.log(EkfLogEntry(monotonicMs: 100, wallClockMs: 0));
      await logger.endSession();

      await logger.startSession();
      expect(logger.entryCount, 0);
      logger.log(EkfLogEntry(monotonicMs: 200, wallClockMs: 0));
      expect(logger.entryCount, 1);
      await logger.endSession();
    });

    test('startSession is idempotent', () async {
      await logger.startSession();
      logger.log(EkfLogEntry(monotonicMs: 0, wallClockMs: 0));
      await logger.startSession(); // Should be no-op
      expect(logger.entryCount, 1); // Entry should still be there
      await logger.endSession();
    });

    test('endSession is idempotent', () async {
      await logger.startSession();
      await logger.endSession();
      await logger.endSession(); // Should be no-op
      expect(logger.isActive, isFalse);
    });
  });

  group('EkfLogger integration', () {
    test('logs EKF state transitions correctly', () async {
      final logger = EkfLogger();
      await logger.startSession();

      // Simulate IMU → GPS → ZUPT sequence
      logger.logImu(
        timestamp: const Duration(milliseconds: 0),
        ax: 0.0,
        ay: 0.0,
        az: 9.81,
        gx: 0.0,
        gy: 0.0,
        gz: 0.0,
        ekfState: const EkfPublicState(
          s: 0.0,
          v: 0.0,
          sigmaS: 100.0,
          sigmaV: 5.0,
          biasA: 0.0,
          mode: EkfMode.degraded,
          motion: MotionState.stationary,
        ),
        motionState: 'stationary',
        mode: EkfMode.degraded,
      );

      logger.logGps(
        timestamp: const Duration(milliseconds: 100),
        lat: 12.9716,
        lng: 77.5946,
        accuracy: 10.0,
        innovation: 20.0,
        innovationSigma: 1.5,
        ekfState: const EkfPublicState(
          s: 50.0,
          v: 0.0,
          sigmaS: 10.0,
          sigmaV: 2.0,
          biasA: 0.0,
          mode: EkfMode.surface,
          motion: MotionState.vehicle,
        ),
        mode: EkfMode.surface,
      );

      logger.logZupt(
        timestamp: const Duration(milliseconds: 200),
        confirmed: true,
        dwellSeconds: 5.0,
        ekfState: const EkfPublicState(
          s: 55.0,
          v: 0.0,
          sigmaS: 8.0,
          sigmaV: 0.1,
          biasA: 0.01,
          mode: EkfMode.metro,
          motion: MotionState.stationary,
        ),
        stationSnapIndex: 1,
      );

      expect(logger.entryCount, 3);
      await logger.endSession();
    });
  });
}
