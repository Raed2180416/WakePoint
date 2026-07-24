import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:app_settings/app_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:geowake2/services/oem_autostart_service.dart';
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

    // 4. Reliability setup (non-critical): battery-optimization exemption +
    //    OEM autostart allowlist. Doze/OEM task-killers are the #1 cause of a
    //    missed wake-up, so we surface this once, best-effort.
    await _runReliabilitySetup();

    return true;
  }

  /// G2: guide the user through battery-optimization exemption and, on
  /// aggressive OEM ROMs, the autostart allowlist. Non-blocking: tracking still
  /// works if the user skips, it is just less reliable.
  Future<void> _runReliabilitySetup() async {
    if (!Platform.isAndroid) return;

    // Only prompt once so we don't nag on every launch.
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('reliability_setup_done') == true) return;

    final packageName = (await PackageInfo.fromPlatform()).packageName;

    final proceed = await _showRationaleDialog(
      'Keep Alarms Reliable',
      'To make sure GeoWake can wake you even with the screen off, please '
      'allow it to ignore battery optimization, and (on some phones) enable '
      'Auto-start. We will open the right settings screens next.',
    );
    if (!proceed) return;

    await OemAutostartService.requestIgnoreBatteryOptimizations(packageName);

    if (await OemAutostartService.isAggressiveOem()) {
      final openAutostart = await _showRationaleDialog(
        'Enable Auto-start',
        'Your phone\'s manufacturer may stop GeoWake in the background. On the '
        'next screen, please turn ON Auto-start / background activity for GeoWake.',
      );
      if (openAutostart) {
        await OemAutostartService.openAutoStartSettings();
      }
    }

    await prefs.setBool('reliability_setup_done', true);
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

    // Play "prominent disclosure" for background location: this dialog MUST be
    // shown in-app immediately before the OS "all the time" prompt, must state
    // that location is collected even when the app is closed/not in use, must
    // name the single purpose (the wake alarm), must promise no other use, and
    // must offer a real decline. Wording is kept in lockstep with the hosted
    // privacy policy — a mismatch here is a top Play rejection cause.
    final bool didAgree = await _showRationaleDialog(
      "Allow location \"all the time\"",
      "GeoWake collects your location in the background — even when the app is "
          "closed or not in use — for one purpose only: to track your transit "
          "journey and sound the wake-up alarm before your stop.\n\n"
          "Your location is never used for advertising and never sold. On the "
          "next screen, choose \"Allow all the time\" to enable the alarm while "
          "you sleep. You can decline and still use GeoWake with the screen on.",
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