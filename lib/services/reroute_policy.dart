import 'dart:async';

class RerouteDecision {
  final bool shouldReroute;
  final DateTime at;
  const RerouteDecision(this.shouldReroute, this.at);
}

class ReroutePolicy {
  final Duration cooldown;
  bool _online;
  DateTime? _lastRerouteAt;

  final _decisionCtrl = StreamController<RerouteDecision>.broadcast();
  Stream<RerouteDecision> get stream => _decisionCtrl.stream;

  ReroutePolicy({Duration cooldown = const Duration(seconds: 20), bool initialOnline = true})
      : cooldown = cooldown,
        _online = initialOnline;

  void setOnline(bool online) {
    _online = online;
  }

  bool _cooldownActive(DateTime now) =>
      _lastRerouteAt != null && now.difference(_lastRerouteAt!) < cooldown;

  void onSustainedDeviation({required DateTime at}) {
    final now = at;
    if (!_online) {
      _decisionCtrl.add(RerouteDecision(false, now));
      return;
    }
    if (_cooldownActive(now)) {
      _decisionCtrl.add(RerouteDecision(false, now));
      return;
    }
    _lastRerouteAt = now;
    _decisionCtrl.add(RerouteDecision(true, now));
  }

  void dispose() {
    _decisionCtrl.close();
  }
}
