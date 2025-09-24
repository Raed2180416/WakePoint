// Annotated copy of lib/services/deviation_monitor.dart
// Purpose: Explain every line, each block, decision logic, and outputs.

import 'dart:async'; // Imports StreamController and Duration for streaming deviation states over time

class DeviationState { // Immutable snapshot of deviation at a moment in time
  final bool offroute; // Whether current offset is above the high threshold (or still above the low threshold during sustain)
  final bool sustained; // Whether offroute has been sustained for at least sustainDuration
  final double offsetMeters; // Current lateral distance to route (meters)
  final double speedMps; // Current speed in meters per second (used for speed-adaptive thresholds)
  final DateTime at; // Timestamp of the state
  const DeviationState({ // Const constructor for immutability
    required this.offroute, // True if we are offroute (above T_high) or not yet back below T_low
    required this.sustained, // True only after sustain window elapsed while remaining offroute
    required this.offsetMeters, // Observed lateral offset
    required this.speedMps, // Observed speed
    required this.at, // Time of evaluation
  }); // End constructor
} // End class DeviationState

class SpeedThresholdModel { // Parameterized thresholds model with hysteresis to avoid flapping
  // T_high = base + k * speed; T_low = hysteresisRatio * T_high
  final double base; // Base threshold at zero speed
  final double k; // Linear coefficient w.r.t. speed for T_high
  final double hysteresisRatio; // Ratio to compute T_low from T_high (0..1), lower to increase stickiness
  const SpeedThresholdModel({this.base = 15.0, this.k = 1.5, this.hysteresisRatio = 0.7}); // Defaults tuned for walking/cycling

  double high(double speedMps) => base + k * speedMps; // Compute T_high as a function of speed
  double low(double speedMps) => hysteresisRatio * high(speedMps); // Compute T_low for hysteresis band
} // End class SpeedThresholdModel

class DeviationMonitor { // Tracks offroute status with sustain and hysteresis over a stream of measurements
  final Duration sustainDuration; // Window to consider offroute "sustained"
  final SpeedThresholdModel model; // Threshold model for adaptive bands

  final _stateCtrl = StreamController<DeviationState>.broadcast(); // Broadcast stream so multiple listeners can subscribe
  Stream<DeviationState> get stream => _stateCtrl.stream; // Public stream of deviation state updates

  DateTime? _deviatingSince; // When we first crossed T_high (start of offroute)
  bool _offroute = false; // Current offroute status
  bool _sustained = false; // Whether sustain window elapsed while remaining offroute

  DeviationMonitor({ // Constructor with defaults
    this.sustainDuration = const Duration(seconds: 5), // Default sustain window of 5 seconds
    this.model = const SpeedThresholdModel(), // Default thresholds model
  }); // End constructor

  void ingest({required double offsetMeters, required double speedMps, DateTime? at}) { // Process one measurement
    final now = at ?? DateTime.now(); // Timestamp for this sample
    final th = model.high(speedMps); // Compute high threshold (enter offroute)
    final tl = model.low(speedMps); // Compute low threshold (exit offroute)

    if (!_offroute) { // If currently considered on-route
      if (offsetMeters > th) { // Enter offroute when offset exceeds T_high
        _offroute = true; // Flip to offroute
        _deviatingSince = now; // Mark start time of deviation
        _sustained = false; // Reset sustained
      } // End enter-offroute
    } else { // Already offroute
      if (offsetMeters < tl) { // Exit offroute only when offset drops below T_low
        _offroute = false; // Back on route
        _sustained = false; // Reset sustained
        _deviatingSince = null; // Clear start time
      } else { // Still offroute
        if (!_sustained && _deviatingSince != null && now.difference(_deviatingSince!) >= sustainDuration) { // Check sustain window
          _sustained = true; // Mark sustained deviation
        }
      }
    }

    _stateCtrl.add(DeviationState( // Emit current state
      offroute: _offroute, // Offroute flag
      sustained: _sustained, // Sustained flag
      offsetMeters: offsetMeters, // Current offset for diagnostics
      speedMps: speedMps, // Current speed used to compute thresholds
      at: now, // Timestamp
    )); // End emit
  } // End ingest()

  void reset() { // Reset internal state to on-route
    _offroute = false; // Back to on-route
    _sustained = false; // No sustain
    _deviatingSince = null; // Clear timer
  } // End reset

  void dispose() { // Close stream controller to release resources
    _stateCtrl.close(); // Close broadcast stream
  } // End dispose
} // End class DeviationMonitor

/* Block summary: ingest() applies a classic hysteresis band with sustain timing. Enter offroute when offset > T_high,
   and return to on-route only when offset < T_low (T_low < T_high) to avoid toggling near the boundary. A sustain window
   marks deviations that persist beyond a duration, enabling policies like local switching or rerouting. */

/* File summary: DeviationMonitor produces a time-series of offroute states consumed by TrackingService and
   ActiveRouteManager. The speed-adaptive thresholds allow higher tolerance at higher speeds. The sustain flag is used
   to gate expensive operations (alerts/reroutes) until the user is clearly deviating, reducing false positives. */
