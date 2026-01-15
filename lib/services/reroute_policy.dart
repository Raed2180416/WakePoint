import 'dart:async';

import 'package:geowake2/dashboard/constraint_logger.dart';

class RerouteDecision {
  final bool shouldReroute;
  final DateTime at;
  const RerouteDecision(this.shouldReroute, this.at);
}

class ReroutePolicy {
  Duration _cooldown;
  bool _online;
  DateTime? _lastRerouteAt;

  final _decisionCtrl = StreamController<RerouteDecision>.broadcast();
  Stream<RerouteDecision> get stream => _decisionCtrl.stream;

  ReroutePolicy({
    Duration cooldown = const Duration(seconds: 20),
    bool initialOnline = true,
  }) : _cooldown = cooldown,
       _online = initialOnline;

  Duration get cooldown => _cooldown;
  void setCooldown(Duration newCooldown) {
    _cooldown = newCooldown;
  }

  void setOnline(bool online) {
    _online = online;
  }

  bool _cooldownActive(DateTime now) =>
      _lastRerouteAt != null && now.difference(_lastRerouteAt!) < _cooldown;

  void onSustainedDeviation({required DateTime at}) {
    final now = at;
    if (!_online) {
      // Log the skip due to offline
      ConstraintLogger.instance.log(
        ConstraintEvent(
          type: ConstraintEventType.rerouteSkipped,
          timestamp: now,
          title: 'Reroute Skipped',
          description: 'Device is offline',
          details: {'reason': 'offline'},
        ),
      );
      _decisionCtrl.add(RerouteDecision(false, now));
      return;
    }
    if (_cooldownActive(now)) {
      // Log the skip due to cooldown
      final remaining = _cooldown - now.difference(_lastRerouteAt!);
      ConstraintLogger.instance.log(
        ConstraintEvent(
          type: ConstraintEventType.rerouteSkipped,
          timestamp: now,
          title: 'Reroute Skipped',
          description: 'Cooldown active (${remaining.inSeconds}s remaining)',
          details: {
            'reason': 'cooldown',
            'remainingMs': remaining.inMilliseconds,
          },
        ),
      );
      _decisionCtrl.add(RerouteDecision(false, now));
      return;
    }
    _lastRerouteAt = now;

    // Log the reroute trigger
    ConstraintLogger.instance.log(
      ConstraintEvent(
        type: ConstraintEventType.rerouteTriggered,
        timestamp: now,
        title: 'Reroute Triggered',
        description: 'Initiating route recalculation',
        details: {'cooldownMs': _cooldown.inMilliseconds},
      ),
    );

    _decisionCtrl.add(RerouteDecision(true, now));
  }

  void dispose() {
    _decisionCtrl.close();
  }
}
