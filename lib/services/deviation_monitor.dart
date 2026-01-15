import 'dart:async';

import 'package:geowake2/core/clock/app_clock.dart';
import 'package:geowake2/dashboard/constraint_logger.dart';

class DeviationState {
  final bool offroute;
  final bool sustained;
  final double offsetMeters;
  final double speedMps;
  final DateTime at;
  const DeviationState({
    required this.offroute,
    required this.sustained,
    required this.offsetMeters,
    required this.speedMps,
    required this.at,
  });
}

class SpeedThresholdModel {
  // T_high = base + k * speed; T_low = hysteresisRatio * T_high
  final double base;
  final double k;
  final double hysteresisRatio;
  const SpeedThresholdModel({
    this.base = 15.0,
    this.k = 1.5,
    this.hysteresisRatio = 0.7,
  });

  double high(double speedMps) => base + k * speedMps;
  double low(double speedMps) => hysteresisRatio * high(speedMps);
}

class DeviationMonitor {
  final Duration sustainDuration;
  final SpeedThresholdModel model;

  final _stateCtrl = StreamController<DeviationState>.broadcast();
  Stream<DeviationState> get stream => _stateCtrl.stream;

  DateTime? _deviatingSince;
  bool _offroute = false;
  bool _sustained = false;

  DeviationMonitor({
    this.sustainDuration = const Duration(seconds: 5),
    this.model = const SpeedThresholdModel(),
  });

  void ingest({
    required double offsetMeters,
    required double speedMps,
    DateTime? at,
  }) {
    final now = at ?? AppClock().now();
    final th = model.high(speedMps);
    final tl = model.low(speedMps);

    if (!_offroute) {
      if (offsetMeters > th) {
        _offroute = true;
        _deviatingSince = now;
        _sustained = false;

        // Log deviation detected
        ConstraintLogger.instance.log(
          ConstraintEvent.deviationDetected(
            timestamp: now,
            offsetMeters: offsetMeters,
            thresholdMeters: th,
          ),
        );
      }
    } else {
      // currently deviating
      if (offsetMeters < tl) {
        // back on route
        _offroute = false;
        _sustained = false;
        _deviatingSince = null;

        // Log back on route
        ConstraintLogger.instance.log(
          ConstraintEvent(
            type: ConstraintEventType.backOnRoute,
            timestamp: now,
            title: 'Back on Route',
            description:
                'Returned within ${offsetMeters.toStringAsFixed(1)}m (threshold: ${tl.toStringAsFixed(0)}m)',
            details: {'offsetMeters': offsetMeters, 'thresholdMeters': tl},
          ),
        );
      } else {
        // still offroute; check sustain
        if (!_sustained &&
            _deviatingSince != null &&
            now.difference(_deviatingSince!) >= sustainDuration) {
          _sustained = true;

          // Log deviation sustained
          ConstraintLogger.instance.log(
            ConstraintEvent.deviationSustained(
              timestamp: now,
              duration: now.difference(_deviatingSince!),
              offsetMeters: offsetMeters,
            ),
          );
        }
      }
    }

    _stateCtrl.add(
      DeviationState(
        offroute: _offroute,
        sustained: _sustained,
        offsetMeters: offsetMeters,
        speedMps: speedMps,
        at: now,
      ),
    );
  }

  void reset() {
    _offroute = false;
    _sustained = false;
    _deviatingSince = null;
  }

  void dispose() {
    _stateCtrl.close();
  }
}
