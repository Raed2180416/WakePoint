import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'services/trackingservice.dart';
import 'screens/homescreen.dart';
import 'screens/maptracking.dart';
import 'screens/otherimpservices/preload_map_screen.dart';
import 'screens/splash_screen.dart';
import 'themes/appthemes.dart';
import 'screens/otherimpservices/recent_locations_service.dart';
import 'services/notification_service.dart';
import 'dart:developer' as dev;

Future<void> main() async {
  // Ensure Flutter binding is initialized before any Flutter-specific code.
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize Hive itself. We will let the service manage opening the box.
  try {
    await Hive.initFlutter();
    dev.log("Hive engine initialized successfully.", name: "main");
  } catch (e) {
    dev.log("FATAL: Hive initialization failed: $e", name: "main");
  }
  
  // Initialize other essential services.
  await _initializeServices();
  
  runApp(const MyApp());
}

// Separate function to keep service initializations clean.
Future<void> _initializeServices() async {
  try {
    await NotificationService().initialize();
  } catch (e) {
    dev.log("Notification Service initialization failed: $e", name: "main");
  }

  try {
    await TrackingService().initializeService();
  } catch (e) {
    dev.log("Tracking Service initialization failed: $e", name: "main");
  }
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  MyAppState createState() => MyAppState();
}

class MyAppState extends State<MyApp> with WidgetsBindingObserver {
  bool isDarkMode = false;

  @override
  void initState() {
    super.initState();
    // Start listening for app lifecycle events (pause, resume, etc.).
    WidgetsBinding.instance.addObserver(this);
    
    // =======================================================================
    // FIX: Call the permission check function here.
    // =======================================================================
    _checkNotificationPermission();
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
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GeoWake',
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