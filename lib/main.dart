import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:geowake2/services/trackingservice.dart';
import 'package:geowake2/services/telemetry/telemetry_service.dart';
import 'package:geowake2/services/monetization/monetization_service.dart';
import 'package:path_provider/path_provider.dart';
import 'services/navigation_service.dart';
import 'dart:developer' as dev;
import 'screens/homescreen.dart';
import 'screens/monetization/paywall_screen.dart';

import 'screens/maptracking.dart';
import 'screens/otherimpservices/preload_map_screen.dart';
import 'screens/splash_screen.dart';
import 'themes/appthemes.dart';
import 'screens/otherimpservices/recent_locations_service.dart';

import 'package:shared_preferences/shared_preferences.dart';

Future<void> main() async {
  // BLOCKER FIX (HANDOFF §3): a reliability-critical app must never die silently.
  // Route every uncaught Flutter/async error to telemetry (and the log) instead
  // of an unrecorded crash in the tracking isolate. runZonedGuarded catches
  // async errors; FlutterError.onError catches widget-tree/framework errors;
  // PlatformDispatcher.onError catches otherwise-unhandled platform errors.
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    TelemetryService.instance
        .recordError(details.exception, details.stack, fatal: false);
  };
  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    TelemetryService.instance.recordError(error, stack, fatal: true);
    return true; // handled — do not crash the isolate
  };

  await runZonedGuarded<Future<void>>(() async {
    WidgetsFlutterBinding.ensureInitialized();
    // PLAY COMPLIANCE (targetSdk 35 / Android 15): edge-to-edge is enforced, so
    // opt in explicitly and make the system bars transparent (Scaffolds already
    // use SafeArea, so content is not occluded).
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
    ));
    // Ensure Flutter binding is initialized before any Flutter-specific code.
    await Hive.initFlutter();

    // Persist telemetry to a durable JSONL sink so events survive process death
    // (BACKLOG #7 + #16). path_provider stays OUT of TelemetryService — resolve
    // the dir here and inject it. Fire-and-forget so a slow disk can't delay
    // startup; the in-memory sink keeps working until the file sink is wired.
    unawaited(() async {
      try {
        final supportDir = await getApplicationSupportDirectory();
        TelemetryService.instance.configureDefaultSinks(dir: supportDir.path);
      } catch (_) {/* telemetry is best-effort; never block or crash startup */}
    }());

    // Service initialization moved to SplashScreen to improve startup time.

    // Assemble monetization (entitlement + store + ads) off the critical path —
    // gates safely default to "free" until it's ready; the core alarm never
    // depends on it. Fire-and-forget so a slow store/ad SDK can't delay startup.
    unawaited(MonetizationService.instance.init());

    runApp(const MyApp());
  }, (Object error, StackTrace stack) {
    TelemetryService.instance.recordError(error, stack, fatal: true);
    dev.log('Uncaught zone error: $error', name: 'main', error: error, stackTrace: stack);
  });
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  MyAppState createState() => MyAppState();
}

class MyAppState extends State<MyApp> with WidgetsBindingObserver {
  bool isDarkMode = false;
  static const _themePrefKey = 'gw_dark_mode';

  @override
  void initState() {
    super.initState();
    // Start listening for app lifecycle events (pause, resume, etc.).
    WidgetsBinding.instance.addObserver(this);

    // =======================================================================
    // FIX: Call the permission check function here.
    // =======================================================================
    _checkNotificationPermission();
    _restoreThemePreference();
  }

  @override
  void dispose() {
    // Stop listening to prevent memory leaks.
    WidgetsBinding.instance.removeObserver(this);
    // As a final cleanup when the app is truly closing, close Hive.
    Hive.close();
    super.dispose();
  }

  // This is the definitive fix for saving data before the app closes.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // This is called when the user backgrounds the app (e.g., presses home).
    if (state == AppLifecycleState.paused) {
      dev.log("App paused, flushing Hive box to disk.", name: "main");
      // `flush()` is a direct command to write all in-memory changes to disk.
      // This prevents the OS from killing the app before data is saved.
      if (Hive.isBoxOpen(RecentLocationsService.boxName)) {
        Hive.box(RecentLocationsService.boxName).flush();
      }
    }

    // Allow the tracking service to mirror lifecycle transitions for its own bookkeeping.
    TrackingService().handleAppLifecycleChange(state);
  }

  /// Check and request notification permission on Android 13+ or iOS.
  Future<void> _checkNotificationPermission() async {
    final status = await Permission.notification.status;
    if (status.isDenied) {
      await Permission.notification.request();
    }
  }

  void toggleTheme() {
    setState(() {
      isDarkMode = !isDarkMode;
    });
    _persistThemePreference(isDarkMode);
  }

  Future<void> _restoreThemePreference() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getBool(_themePrefKey);
      if (stored != null) {
        setState(() {
          isDarkMode = stored;
        });
      }
    } catch (e) {
      dev.log('Failed to restore theme preference: $e', name: 'main');
    }
  }

  Future<void> _persistThemePreference(bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_themePrefKey, value);
    } catch (e) {
      dev.log('Failed to persist theme preference: $e', name: 'main');
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GeoWake',
      navigatorKey: NavigationService.navigatorKey,
      theme: isDarkMode ? AppThemes.darkTheme : AppThemes.lightTheme,
      initialRoute: '/splash',
      onGenerateRoute: (settings) {
        if (settings.name == '/splash') {
          return MaterialPageRoute(
            builder: (_) => const SplashScreen(),
            settings: settings,
          );
        }
        if (settings.name == '/preloadMap') {
          final args = settings.arguments as Map<String, dynamic>;
          return MaterialPageRoute(
            builder: (_) => PreloadMapScreen(arguments: args),
            settings: settings,
          );
        }
        if (settings.name == '/mapTracking') {
          return MaterialPageRoute(
            builder: (_) => MapTrackingScreen(),
            settings: settings,
          );
        }
        if (settings.name == '/') {
          return MaterialPageRoute(builder: (_) => const HomeScreen());
        }
        if (settings.name == '/paywall') {
          // The single upsell surface. Arg is an optional PaywallSource.
          return MaterialPageRoute(
            builder: (_) => const GeoWakePaywallScreen(),
            settings: settings,
          );
        }
        return null;
      },
    );
  }
}
