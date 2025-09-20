import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:app_settings/app_settings.dart';
import 'dart:io' show Platform;

class PermissionService {
  final BuildContext context;

  PermissionService(this.context);

  /// Initiates the full, user-friendly flow for all essential permissions.
  /// Returns `true` if all critical permissions are granted.
  Future<bool> requestEssentialPermissions() async {
    // 1. Handle Location Permissions
    bool locationGranted = await _requestLocationPermission();
    if (!locationGranted) return false;

    // 2. Handle Notification Permission
    bool notificationsGranted = await _requestNotificationPermission();
    if (!notificationsGranted) return false;

    // 3. Handle Activity Recognition (non-critical)
    await _requestActivityRecognitionPermission();
    
    return true;
  }

  // --- Private Helper Methods for Each Permission ---

  Future<bool> _requestLocationPermission() async {
    PermissionStatus status = await Permission.location.status;

    if (status.isPermanentlyDenied) {
      await _showSettingsDialog(
        "Location is Crucial",
        "GeoWake needs your location to track your journey. Please enable it in your device settings."
      );
      return false;
    }
    
    if (!status.isGranted) {
      final bool didAgree = await _showRationaleDialog(
        "Why We Need Location",
        "To monitor your trip and alert you before your stop, GeoWake requires access to your location."
      );
      if (!didAgree) return false;
      
      status = await Permission.location.request();
    }
    
    if (status.isGranted) {
      // If location is granted, immediately ask for background location which is essential.
      return await _requestBackgroundLocation();
    }
    
    return false;
  }

  Future<bool> _requestBackgroundLocation() async {
    PermissionStatus status = await Permission.locationAlways.status;
    if (status.isGranted) return true;

    // For background location, we can show a rationale dialog as well.
    final bool didAgree = await _showRationaleDialog(
        "Enable Background Tracking",
        "For GeoWake to work reliably even when the app isn't open, please allow location access 'all the time'."
    );
    if (!didAgree) return false;
    
    status = await Permission.locationAlways.request();
    return status.isGranted;
  }

  Future<bool> _requestNotificationPermission() async {
    if (!Platform.isAndroid) return true; // Not needed on iOS in the same way

    PermissionStatus status = await Permission.notification.status;
    if (status.isGranted) return true;

    if (status.isPermanentlyDenied) {
      await _showSettingsDialog(
        "Notifications are Important",
        "We need to send you a notification to wake you up! Please enable notifications in your device settings."
      );
      return false;
    }
    
    status = await Permission.notification.request();
    return status.isGranted;
  }
  
  Future<void> _requestActivityRecognitionPermission() async {
    if (!Platform.isAndroid) return;
    PermissionStatus status = await Permission.activityRecognition.status;
    if (!status.isGranted) {
      // This is less critical, so we can just request it without a complex flow.
      await Permission.activityRecognition.request();
    }
  }


  // --- Reusable Dialogs ---

  /// Shows the "Soft Ask" dialog to explain why a permission is needed.
  Future<bool> _showRationaleDialog(String title, String message) async {
    if (!context.mounted) return false;
    return await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            child: const Text("Not Now"),
            onPressed: () => Navigator.of(context).pop(false),
          ),
          TextButton(
            child: const Text("Continue"),
            onPressed: () => Navigator.of(context).pop(true),
          ),
        ],
      ),
    ) ?? false;
  }

  /// Shows the "Hard Ask" dialog to go to settings when permanently denied.
  Future<void> _showSettingsDialog(String title, String message) async {
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            child: const Text("Cancel"),
            onPressed: () => Navigator.of(context).pop(),
          ),
          TextButton(
            child: const Text("Open Settings"),
            onPressed: () {
              AppSettings.openAppSettings();
              Navigator.of(context).pop();
            },
          ),
        ],
      ),
    );
  }
}