import 'dart:async';
import 'dart:developer' as dev;
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geowake2/services/tracking_state_store.dart';

class TestServiceInstance implements ServiceInstance {
  final _eventControllers =
      <String, StreamController<Map<String, dynamic>?>?>{};
  @override
  void invoke(String method, [Map<String, dynamic>? args]) {
    dev.log("Test service invoke: $method, args: $args", name: "TestService");
    if (method == 'triggerAlarm') {
      TrackingStateStore.setAlarmFired(true);
    }
  }

  @override
  Future<void> stopSelf() async {
    dev.log("Test service stopped", name: "TestService");
  }

  @override
  Stream<Map<String, dynamic>?> on(String event) {
    _eventControllers.putIfAbsent(
      event,
      () => StreamController<Map<String, dynamic>?>.broadcast(),
    );
    return _eventControllers[event]!.stream;
  }

  void dispose() {
    for (var controller in _eventControllers.values) {
      controller?.close();
    }
  }
}
