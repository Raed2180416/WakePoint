// Annotated copy of lib/services/permission_service.dart
// Purpose: Explain friendly, staged permission requests with rationale and settings fallbacks.

import 'package:flutter/material.dart'; // UI dialogs
import 'package:permission_handler/permission_handler.dart'; // Permission checks/requests
import 'package:app_settings/app_settings.dart'; // Open OS settings
import 'dart:io' show Platform; // Platform detection

class PermissionService {
  final BuildContext context; // For showing dialogs
  PermissionService(this.context);

  // Orchestrates all key permissions; returns true when essentials are granted
  Future<bool> requestEssentialPermissions() async {
    // Location first (includes background)
    final locationGranted = await _requestLocationPermission();
    if (!locationGranted) return false;

    // Then notifications (Android 13+)
    final notificationsGranted = await _requestNotificationPermission();
    if (!notificationsGranted) return false;

    // Nice-to-have: activity recognition (Android only)
    await _requestActivityRecognitionPermission();
    return true;
  }

  // --- Private helpers ---

  Future<bool> _requestLocationPermission() async {
    var status = await Permission.location.status;
    if (status.isPermanentlyDenied) {
      await _showSettingsDialog('Location is Crucial', 'GeoWake needs your location to track your journey. Please enable it in your device settings.');
      return false;
    }
    if (!status.isGranted) {
      final didAgree = await _showRationaleDialog('Why We Need Location', 'To monitor your trip and alert you before your stop, GeoWake requires access to your location.');
      if (!didAgree) return false;
      status = await Permission.location.request();
    }
    if (status.isGranted) {
      return await _requestBackgroundLocation();
    }
    return false;
  }

  Future<bool> _requestBackgroundLocation() async {
    var status = await Permission.locationAlways.status;
    if (status.isGranted) return true;
    final didAgree = await _showRationaleDialog('Enable Background Tracking', "For GeoWake to work reliably even when the app isn't open, please allow location access 'all the time'.");
    if (!didAgree) return false;
    status = await Permission.locationAlways.request();
    return status.isGranted;
  }

  Future<bool> _requestNotificationPermission() async {
    if (!Platform.isAndroid) return true; // iOS flow differs and is handled elsewhere
    var status = await Permission.notification.status;
    if (status.isGranted) return true;
    if (status.isPermanentlyDenied) {
      await _showSettingsDialog('Notifications are Important', 'We need to send you a notification to wake you up! Please enable notifications in your device settings.');
      return false;
    }
    status = await Permission.notification.request();
    return status.isGranted;
  }

  Future<void> _requestActivityRecognitionPermission() async {
    if (!Platform.isAndroid) return;
    final status = await Permission.activityRecognition.status;
    if (!status.isGranted) { await Permission.activityRecognition.request(); }
  }

  // --- Reusable dialogs ---

  Future<bool> _showRationaleDialog(String title, String message) async {
    if (!context.mounted) return false;
    return await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(child: const Text('Not Now'), onPressed: () => Navigator.of(context).pop(false)),
          TextButton(child: const Text('Continue'), onPressed: () => Navigator.of(context).pop(true)),
        ],
      ),
    ) ?? false;
  }

  Future<void> _showSettingsDialog(String title, String message) async {
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(child: const Text('Cancel'), onPressed: () => Navigator.of(context).pop()),
          TextButton(child: const Text('Open Settings'), onPressed: () { AppSettings.openAppSettings(); Navigator.of(context).pop(); }),
        ],
      ),
    );
  }
}
