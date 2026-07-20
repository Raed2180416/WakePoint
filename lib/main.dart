import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_driver/driver_extension.dart';
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
import 'screens/mobility_data_consent_screen.dart';
import 'services/data_asset/data_asset_pipeline.dart';
import 'services/widget/home_widget_bridge.dart';
import 'screens/guardian_setup_screen.dart';
import 'screens/monetization/post_arrival_screen.dart';
import 'screens/friends_rides_screen.dart';
import 'screens/report_problem_screen.dart';
import 'package:geolocator/geolocator.dart';
import 'package:app_links/app_links.dart';
import 'services/share/share_backend_config.dart';
import 'services/share/guardian_service.dart';
import 'services/share/journey_share_service.dart';
import 'services/share/followed_rides_service.dart';
import 'services/share/share_deep_link.dart';

import 'screens/maptracking.dart';
import 'screens/otherimpservices/preload_map_screen.dart';
import 'screens/splash_screen.dart';
import 'themes/appthemes.dart';
import 'screens/otherimpservices/recent_locations_service.dart';

import 'package:shared_preferences/shared_preferences.dart';

// Network telemetry egress config (INERT by default). Supplied at build time via
// --dart-define; empty => no network sink is registered and nothing ships
// off-device. The actual server + token are businessGated (founder-owned).
const String _telemetryUrl =
    String.fromEnvironment('GEOWAKE_TELEMETRY_URL', defaultValue: '');
const String _telemetryToken =
    String.fromEnvironment('GEOWAKE_TELEMETRY_TOKEN', defaultValue: '');

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
    _markSessionCrashed();
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
    // Optional network egress, INERT by default: the endpoint/token come from
    // --dart-define (GEOWAKE_TELEMETRY_URL / GEOWAKE_TELEMETRY_TOKEN) and default
    // to ''. An empty URL registers NO http sink, so telemetry stays PII-free +
    // local-only until the founder supplies a backend.
    unawaited(() async {
      try {
        final supportDir = await getApplicationSupportDirectory();
        TelemetryService.instance.configureDefaultSinks(
          dir: supportDir.path,
          telemetryUrl: _telemetryUrl,
          telemetryToken: _telemetryToken,
        );
      } catch (_) {/* telemetry is best-effort; never block or crash startup */}
    }());

    // Service initialization moved to SplashScreen to improve startup time.

    // Assemble monetization (entitlement + store + ads) off the critical path —
    // gates safely default to "free" until it's ready; the core alarm never
    // depends on it. Fire-and-forget so a slow store/ad SDK can't delay startup.
    unawaited(MonetizationService.instance.init());
    // Guardian mode (Pro): load persisted state and register the POST-ALARM
    // "arrived safely" observer. The observer hangs off PostAlarmMulticast, so it
    // runs AFTER the wake has already fired + tracking torn down — it can never
    // delay, reorder, or abort the arm→track→alarm spine. Fire-and-forget and
    // fail-open to disabled; inert unless the user is Pro + turned Guardian on.
    unawaited(GuardianService.instance.init());
    // On-device mobility aggregator: consent defaults OFF and egress is a no-op,
    // so init is inert until the user opts in. Never blocks startup.
    unawaited(DataAssetPipeline.instance.init());

    // Home-screen widget bridge: registers widget-tap handling and paints an
    // initial card. Fail-open — a missing/broken home_widget plugin disables the
    // bridge for the session (see HomeWidgetBridge.initialize). Display/observer
    // only: it reads already-computed state and never touches the arm→track→
    // alarm spine. Fire-and-forget so it can't delay or crash startup.
    unawaited(HomeWidgetBridge.instance.initialize());

    // Journey-share backend (sharer + follower). Fire-and-forget, fail-safe:
    // basic share always works; the live ping/follow path attaches only when the
    // backend + token are configured. Never touches the arm → track → alarm spine.
    unawaited(() async {
      try {
        await ShareBackendConfig.configure();
        // Relay live position to the share backend whenever a share is active.
        // ingestLocation self-gates on an active share, so this is inert
        // otherwise and can never affect tracking or the never-late alarm.
        JourneyShareService.instance.bindTracking<Position>(
          TrackingService().locationStream,
          latOf: (p) => p.latitude,
          lngOf: (p) => p.longitude,
        );
      } catch (_) {/* share is best-effort; never block or crash startup */}
    }());

    // MANDATE §7.1 (black-box drivability): expose the Flutter Driver extension
    // ONLY when built with --dart-define=ENABLE_FLUTTER_DRIVER=true. bool
    // .fromEnvironment defaults to false, so production builds never register
    // the extension — this is a pure no-op unless the dart-define is set, and
    // it never touches the arm → track → alarm spine.
    if (const bool.fromEnvironment('ENABLE_FLUTTER_DRIVER')) {
      enableFlutterDriverExtension();
    }

    runApp(const MyApp());
  }, (Object error, StackTrace stack) {
    TelemetryService.instance.recordError(error, stack, fatal: true);
    _markSessionCrashed();
    dev.log('Uncaught zone error: $error', name: 'main', error: error, stackTrace: stack);
  });
}

/// Persist a best-effort "the app hit a fatal error last session" flag so the
/// next launch can offer to send a diagnostic report. Fire-and-forget; wrapped
/// so it can never re-throw out of an error handler.
const String _kCrashFlagKey = 'gw_last_session_crashed';

void _markSessionCrashed() {
  () async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kCrashFlagKey, true);
    } catch (_) {/* best-effort; never matters */}
  }();
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
    _initShareDeepLinks();
    _maybeOfferCrashReport();
  }

  // Handle GeoWake journey-share deep links (App Links https://<domain>/j/{id}
  // or geowake://j/{id}). Opening one follows that friend's ride + shows the
  // "Friends' rides" screen. Additive + fail-safe; never touches the alarm path.
  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _linkSub;

  Future<void> _initShareDeepLinks() async {
    try {
      final initial = await _appLinks.getInitialLink();
      _handleShareLink(initial);
    } catch (_) {/* no initial link */}
    _linkSub = _appLinks.uriLinkStream.listen(
      _handleShareLink,
      onError: (_) {},
    );
  }

  void _handleShareLink(Uri? uri) {
    final link = ShareDeepLinkParser.parse(uri);
    if (link == null) return;
    () async {
      try {
        await FollowedRidesService.instance.follow(link.id, token: link.token);
        final nav = NavigationService.navigatorKey.currentState;
        nav?.push(MaterialPageRoute(
          builder: (_) => const FriendsRidesScreen(),
        ));
      } catch (_) {/* fail-safe: a bad link never crashes the app */}
    }();
  }

  /// If the previous session ended in a fatal error, offer (once) to send a
  /// diagnostic report. Reads + clears the flag so it prompts at most once.
  Future<void> _maybeOfferCrashReport() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!(prefs.getBool(_kCrashFlagKey) ?? false)) return;
      await prefs.remove(_kCrashFlagKey);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final nav = NavigationService.navigatorKey.currentState;
        final ctx = nav?.overlay?.context;
        if (nav == null || ctx == null) return;
        showDialog<void>(
          context: ctx,
          builder: (dctx) => AlertDialog(
            title: const Text('GeoWake hit a problem'),
            content: const Text(
              'Last time, GeoWake ran into an unexpected error. Send a quick '
              'diagnostic report so it can be fixed? No location or personal '
              'data is included, and you choose where to send it.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dctx).pop(),
                child: const Text('Not now'),
              ),
              FilledButton(
                onPressed: () {
                  Navigator.of(dctx).pop();
                  nav.push(MaterialPageRoute(
                    builder: (_) =>
                        const ReportProblemScreen(crashedLastSession: true),
                  ));
                },
                child: const Text('Report'),
              ),
            ],
          ),
        );
      });
    } catch (_) {/* never block startup */}
  }

  @override
  void dispose() {
    // Stop listening to prevent memory leaks.
    WidgetsBinding.instance.removeObserver(this);
    _linkSub?.cancel();
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
        if (settings.name == '/dataConsent') {
          return MaterialPageRoute(
            builder: (_) => const DataSharingConsentScreen(),
            settings: settings,
          );
        }
        if (settings.name == '/guardian') {
          return MaterialPageRoute(
            builder: (_) => const GuardianSetupScreen(),
            settings: settings,
          );
        }
        if (settings.name == '/postArrival') {
          return MaterialPageRoute(
            builder: (_) => const PostArrivalScreen(),
            settings: settings,
          );
        }
        return null;
      },
    );
  }
}
