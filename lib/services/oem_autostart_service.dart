// lib/services/oem_autostart_service.dart
//
// G2: aggressive-OEM 'autostart' / 'background-permission' deep links.
// Chinese/other OEM ROMs (MIUI, ColorOS, Funtouch, EMUI, OxygenOS, One UI)
// kill background services unless the app is on an OEM-specific allowlist that
// the standard Android battery-optimization screen does NOT cover. We launch the
// exact OEM ComponentName when present, else fall back to app_settings.

import 'dart:io' show Platform;

import 'package:android_intent_plus/android_intent.dart';
import 'package:android_intent_plus/flag.dart';
import 'package:app_settings/app_settings.dart';
import 'package:device_info_plus/device_info_plus.dart';

class OemAutostartService {
  OemAutostartService._();

  /// Per-OEM autostart manager (package, activity component).
  static const List<List<String>> _componentsByManufacturer = [
    // Xiaomi / Redmi / POCO (MIUI)
    ['xiaomi', 'com.miui.securitycenter',
      'com.miui.permcenter.autostart.AutoStartManagementActivity'],
    ['redmi', 'com.miui.securitycenter',
      'com.miui.permcenter.autostart.AutoStartManagementActivity'],
    ['poco', 'com.miui.securitycenter',
      'com.miui.permcenter.autostart.AutoStartManagementActivity'],
    // Oppo / Realme (ColorOS) — several package generations.
    // Modern ColorOS 12+/HyperOS uses the com.oplus.* namespace; these MUST come
    // first so current India-mix Oppo/Realme devices resolve the real autostart
    // screen instead of silently falling back to the generic battery page
    // (com.oplus.safecenter is already declared in AndroidManifest <queries>).
    ['oppo', 'com.oplus.safecenter',
      'com.oplus.safecenter.startup.StartupAppListActivity'],
    ['oppo', 'com.coloros.safecenter',
      'com.coloros.safecenter.startupapp.StartupAppListActivity'],
    ['realme', 'com.oplus.safecenter',
      'com.oplus.safecenter.startup.StartupAppListActivity'],
    ['oppo', 'com.coloros.safecenter',
      'com.coloros.safecenter.permission.startup.StartupAppListActivity'],
    ['oppo', 'com.oppo.safe',
      'com.oppo.safe.permission.startup.StartupAppListActivity'],
    ['realme', 'com.coloros.safecenter',
      'com.coloros.safecenter.startupapp.StartupAppListActivity'],
    // Vivo / iQOO (Funtouch/OriginOS)
    ['vivo', 'com.iqoo.secure',
      'com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity'],
    ['vivo', 'com.vivo.permissionmanager',
      'com.vivo.permissionmanager.activity.BgStartUpManagerActivity'],
    ['iqoo', 'com.iqoo.secure',
      'com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity'],
    // Huawei / Honor (EMUI)
    ['huawei', 'com.huawei.systemmanager',
      'com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity'],
    ['huawei', 'com.huawei.systemmanager',
      'com.huawei.systemmanager.optimize.process.ProtectActivity'],
    ['honor', 'com.huawei.systemmanager',
      'com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity'],
    // OnePlus (OxygenOS)
    ['oneplus', 'com.oneplus.security',
      'com.oneplus.security.chainlaunch.view.ChainLaunchAppListActivity'],
    // Samsung (One UI) — device care; often no direct autostart activity, so this
    // opens device care and we rely on app_settings fallback for the rest.
    ['samsung', 'com.samsung.android.lool',
      'com.samsung.android.sm.ui.battery.BatteryActivity'],
  ];

  /// Returns the lower-cased device manufacturer, or '' off-Android.
  static Future<String> manufacturer() async {
    if (!Platform.isAndroid) return '';
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      return info.manufacturer.toLowerCase();
    } catch (_) {
      return '';
    }
  }

  /// True if this manufacturer is known to need a manual autostart allowlist.
  static Future<bool> isAggressiveOem() async {
    final m = await manufacturer();
    return _componentsByManufacturer.any((row) => m.contains(row[0]));
  }

  /// Attempts to open the OEM autostart screen. Tries each candidate component
  /// for the manufacturer in order; returns true if one launched. Falls back to
  /// the app's battery-optimization settings if none resolve.
  static Future<bool> openAutoStartSettings() async {
    if (!Platform.isAndroid) return false;
    final m = await manufacturer();

    for (final row in _componentsByManufacturer) {
      if (!m.contains(row[0])) continue;
      final intent = AndroidIntent(
        action: 'android.intent.action.MAIN',
        package: row[1],
        componentName: row[2],
        flags: <int>[Flag.FLAG_ACTIVITY_NEW_TASK],
      );
      try {
        // canResolveActivity requires the <queries> package entries (manifest G2).
        final canResolve = await intent.canResolveActivity() ?? false;
        if (canResolve) {
          await intent.launch();
          return true;
        }
      } catch (_) {
        // try next candidate
      }
    }

    // Fallback: OS battery-optimization list (covered by <queries> intent entry).
    try {
      await AppSettings.openAppSettings(type: AppSettingsType.batteryOptimization);
      return true;
    } catch (_) {
      await AppSettings.openAppSettings();
      return false;
    }
  }

  /// G2: ask the OS to exempt the app from Doze/battery optimization.
  /// Uses the direct REQUEST_IGNORE_BATTERY_OPTIMIZATIONS intent (needs the
  /// same-named permission, added to the manifest).
  static Future<void> requestIgnoreBatteryOptimizations(String packageName) async {
    if (!Platform.isAndroid) return;
    final intent = AndroidIntent(
      action: 'android.settings.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS',
      data: 'package:$packageName',
      flags: <int>[Flag.FLAG_ACTIVITY_NEW_TASK],
    );
    try {
      await intent.launch();
    } catch (_) {
      await AppSettings.openAppSettings(
        type: AppSettingsType.batteryOptimization,
      );
    }
  }
}
