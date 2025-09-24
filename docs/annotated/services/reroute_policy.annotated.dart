// Annotated copy of lib/services/reroute_policy.dart
// Purpose: Explain cooldown + connectivity gating and decision streaming.

import 'dart:async'; // StreamController for emitting decisions

class RerouteDecision { // Value object for reroute outcome at a moment
  final bool shouldReroute; // True when reroute is allowed and requested
  final DateTime at; // Timestamp for the decision
  const RerouteDecision(this.shouldReroute, this.at); // Immutable constructor
}

class ReroutePolicy { // Applies connectivity and cooldown constraints to reroute triggers
  // NOTE: cooldown is mutable to preserve stream continuity when updating settings at runtime.
  // Do NOT replace the policy instance — use setCooldown to update in place.
  Duration _cooldown; // Minimum time between reroutes (mutable)
  bool _online; // Current online/offline state
  DateTime? _lastRerouteAt; // Last reroute timestamp

  final _decisionCtrl = StreamController<RerouteDecision>.broadcast(); // Broadcast decisions to listeners
  Stream<RerouteDecision> get stream => _decisionCtrl.stream; // Public stream

  ReroutePolicy({Duration cooldown = const Duration(seconds: 20), bool initialOnline = true})
      : _cooldown = cooldown,
        _online = initialOnline; // Init fields

  // Expose current cooldown value via getter; use setCooldown to update without swapping instances.
  Duration get cooldown => _cooldown;
  void setCooldown(Duration newCooldown) { // Update cooldown while keeping subscribers intact
    _cooldown = newCooldown;
  }

  void setOnline(bool online) { // Update connectivity status
    _online = online;
  }

  bool _cooldownActive(DateTime now) => // Check whether still inside cooldown window
      _lastRerouteAt != null && now.difference(_lastRerouteAt!) < _cooldown;

  void onSustainedDeviation({required DateTime at}) { // Handle sustained deviation event
    final now = at;
    if (!_online) { // Block when offline
      _decisionCtrl.add(RerouteDecision(false, now));
      return;
    }
    if (_cooldownActive(now)) { // Block if cooldown not elapsed
      _decisionCtrl.add(RerouteDecision(false, now));
      return;
    }
    _lastRerouteAt = now; // Record reroute time
    _decisionCtrl.add(RerouteDecision(true, now)); // Emit reroute approval
  }

  void dispose() { // Cleanup the stream
    _decisionCtrl.close();
  }
}

/* File summary:
   - ReroutePolicy is intentionally simple and testable. TrackingService calls onSustainedDeviation() when
     DeviationMonitor marks sustained offroute.
   - The policy enforces online status and cooldown and emits decisions on a broadcast stream.
   - Cooldown is mutable via setCooldown(Duration), allowing runtime updates (e.g., from power policy) without replacing
     the policy instance. This guarantees stream subscribers (like TrackingService) are not dropped. */
