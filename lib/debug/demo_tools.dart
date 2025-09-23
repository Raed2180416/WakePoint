import 'dart:async';
import 'dart:math' as math;
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geowake2/services/trackingservice.dart';
import 'package:geowake2/services/notification_service.dart';
import 'package:geowake2/services/alarm_player.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:developer' as dev;
import 'package:flutter_background_service/flutter_background_service.dart';

class DemoRouteSimulator {
  static StreamController<Position>? _ctrl;

  static Future<void> startDemoJourney({LatLng? origin}) async {
    dev.log('startDemoJourney() called', name: 'DemoRouteSimulator');
    await _ensureNotificationsReady();
    // Ensure real notifications even in test-mode logic path
  NotificationService.isTestMode = false;
  TrackingService.isTestMode = false;
    try { await TrackingService().initializeService(); dev.log('Background service configured', name: 'DemoRouteSimulator'); } catch (e) { dev.log('Init service failed: $e', name: 'DemoRouteSimulator'); }
    try {
      await NotificationService().showJourneyProgress(
        title: 'GeoWake journey',
        subtitle: 'Starting…',
        progress0to1: 0,
      );
    } catch (e) { dev.log('Initial progress notify failed: $e', name: 'DemoRouteSimulator'); }

    final LatLng start = origin ?? const LatLng(12.9600, 77.5855);
    final LatLng dest = _offsetMeters(start, dxMeters: 1200, dyMeters: 0); // ~1.2 km east
    final points = _interpolate(start, dest, 60);

    // Register route directly without network
    TrackingService().registerRoute(
      key: 'demo_route',
      mode: 'driving',
      destinationName: 'Demo Destination',
      points: points,
    );

  // Use injected positions into background service for realistic progress
  FlutterBackgroundService().invoke('useInjectedPositions');
  _ctrl?.close();
  _ctrl = StreamController<Position>();

    // Start tracking with small distance alarm
    dev.log('Starting tracking to demo dest...', name: 'DemoRouteSimulator');
    await TrackingService().startTracking(
      destination: dest,
      destinationName: 'Demo Destination',
      alarmMode: 'distance',
      alarmValue: 0.2, // 200 m before destination
      allowNotificationsInTest: true,
    );

    // Push positions periodically (~18 seconds total)
    int i = 0;
    Timer.periodic(const Duration(milliseconds: 300), (t) {
  dev.log('Demo tick ${i+1}/${points.length}', name: 'DemoRouteSimulator');
      if (_ctrl == null || _ctrl!.isClosed) {
        t.cancel();
        return;
      }
      if (i >= points.length) {
        t.cancel();
        _ctrl!.close();
        return;
      }
      final p = points[i++];
      final pos = Position(
        latitude: p.latitude,
        longitude: p.longitude,
        timestamp: DateTime.now(),
        accuracy: 5.0,
        altitude: 0.0,
        altitudeAccuracy: 0.0,
        heading: 0.0,
        headingAccuracy: 0.0,
        speed: 12.0,
        speedAccuracy: 1.0,
      );
      _ctrl!.add(pos);
      // Send into background service as well, to drive foreground notification progress
      FlutterBackgroundService().invoke('injectPosition', {
        'latitude': pos.latitude,
        'longitude': pos.longitude,
        'accuracy': pos.accuracy,
        'altitude': pos.altitude,
        'altitudeAccuracy': pos.altitudeAccuracy,
        'heading': pos.heading,
        'headingAccuracy': pos.headingAccuracy,
        'speed': pos.speed,
        'speedAccuracy': pos.speedAccuracy,
      });
    });
  }

  static Future<void> triggerTransferAlarmDemo() async {
    dev.log('triggerTransferAlarmDemo() called', name: 'DemoRouteSimulator');
    await _ensureNotificationsReady();
    NotificationService.isTestMode = false;
    await NotificationService().showWakeUpAlarm(
      title: 'Upcoming transfer',
      body: 'Change at Central Station',
      allowContinueTracking: true,
    );
    await AlarmPlayer.playSelected();
  }

  static Future<void> triggerDestinationAlarmDemo() async {
    dev.log('triggerDestinationAlarmDemo() called', name: 'DemoRouteSimulator');
    await _ensureNotificationsReady();
    NotificationService.isTestMode = false;
    await NotificationService().showWakeUpAlarm(
      title: 'Wake Up!',
      body: 'Approaching: Demo Destination',
      allowContinueTracking: false,
    );
    await AlarmPlayer.playSelected();
  }

  static Future<void> _ensureNotificationsReady() async {
    try {
      await NotificationService().initialize();
      dev.log('Notification service initialized', name: 'DemoRouteSimulator');
    } catch (e) { dev.log('Notification init failed: $e', name: 'DemoRouteSimulator'); }
    final status = await Permission.notification.status;
    dev.log('Notification permission status: $status', name: 'DemoRouteSimulator');
    if (!status.isGranted) {
      final req = await Permission.notification.request();
      dev.log('Notification permission requested, result: $req', name: 'DemoRouteSimulator');
    }
  }

  static List<LatLng> _interpolate(LatLng a, LatLng b, int n) {
    final List<LatLng> pts = [];
    for (int i = 0; i < n; i++) {
      final t = i / (n - 1);
      pts.add(LatLng(
        a.latitude + (b.latitude - a.latitude) * t,
        a.longitude + (b.longitude - a.longitude) * t,
      ));
    }
    return pts;
  }

  static LatLng _offsetMeters(LatLng p, {double dxMeters = 0, double dyMeters = 0}) {
    const double earth = 6378137.0;
    final dLat = dyMeters / earth;
    final dLng = dxMeters / (earth * math.cos(math.pi * p.latitude / 180.0));
    final lat = p.latitude + dLat * 180.0 / math.pi;
    final lng = p.longitude + dLng * 180.0 / math.pi;
    return LatLng(lat, lng);
  }
}
