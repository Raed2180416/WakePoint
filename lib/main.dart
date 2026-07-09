import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:geowake2/services/trackingservice.dart';
import 'services/navigation_service.dart';
import 'dart:developer' as dev;
import 'screens/homescreen.dart';

import 'screens/maptracking.dart';
import 'screens/otherimpservices/preload_map_screen.dart';
import 'screens/splash_screen.dart';
import 'themes/appthemes.dart';
import 'screens/otherimpservices/recent_locations_service.dart';

import 'package:shared_preferences/shared_preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Ensure Flutter binding is initialized before any Flutter-specific code.
  await Hive.initFlutter();
  // Service initialization moved to SplashScreen to improve startup time.

  runApp(const MyApp());
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
        return null;
      },
    );
  }
}
