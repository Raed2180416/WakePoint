import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:geowake2/services/tracking_state_store.dart';

import 'package:geowake2/services/trackingservice.dart';
import 'package:geowake2/services/api_client.dart';
import 'package:geowake2/services/notification_service.dart';
import 'package:flutter/foundation.dart'; // for kDebugMode
import 'dart:developer' as dev;

class SplashScreen extends StatefulWidget {
  const SplashScreen({Key? key}) : super(key: key);

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  late AnimationController ringController;
  late AnimationController textController;
  Timer? _textTimer;
  Timer? _navTimer;
  Future<void>? _initFuture;

  @override
  void initState() {
    super.initState();

    // Controller for the pulsing (ringing) effect.
    ringController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);

    // Controller for the fade and slide in of the text.
    textController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );

    // Start text animation slightly after the splash appears.
    _textTimer = Timer(const Duration(milliseconds: 800), () {
      if (!mounted) return;
      textController.forward();
    });

    _initFuture = _initializeServices();
    _checkStateAndNavigate();
  }

  Future<void> _initializeServices() async {
    // Initialize API client FIRST - this secures all API calls
    try {
      await ApiClient.instance.initialize();
      dev.log("API Client initialized successfully.", name: "SplashScreen");
    } catch (e) {
      dev.log("API Client initialization failed: $e", name: "SplashScreen");
    }

    try {
      await NotificationService().initialize();
    } catch (e) {
      dev.log(
        "Notification Service initialization failed: $e",
        name: "SplashScreen",
      );
    }

    try {
      await TrackingService().initializeService();
    } catch (e) {
      dev.log(
        "Tracking Service initialization failed: $e",
        name: "SplashScreen",
      );
    }
  }

  Future<void> _checkStateAndNavigate() async {
    // Check if we are restarting from a killed state where the alarm was firing
    final alarmFired = await TrackingStateStore.isAlarmFired();
    if (alarmFired) {
      // Clean up zombie state (stop service, cancel notifications)
      await TrackingService().completeEndTracking(navigateHome: false);
      if (!mounted) return;
      Navigator.of(context).pushReplacementNamed('/');
      return;
    }

    // Ensure services are initialized before proceeding
    if (_initFuture != null) {
      await _initFuture;
    }

    final restoreSession = await TrackingStateStore.isActive();

    if (restoreSession) {
      // Go straight to tracking; avoid flashing a map during startup.
      if (!mounted) return;
      Navigator.of(context).pushReplacementNamed('/mapTracking');
    } else {
      // Normal splash delay
      _navTimer = Timer(const Duration(seconds: 3), () {
        if (!mounted) return;
        // Go straight home; avoid flashing a map during startup.
        Navigator.of(context).pushReplacementNamed('/');
      });
    }
  }

  @override
  void dispose() {
    _textTimer?.cancel();
    _navTimer?.cancel();
    ringController.dispose();
    textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Load your custom clock logo image.
    final clockImage = Image.asset('assets/geowake.png', width: 150);

    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: scheme.surface,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // AnimatedBuilder creates the pulsing effect.
            AnimatedBuilder(
              animation: ringController,
              builder: (context, child) {
                double scale = 1 + 0.05 * sin(ringController.value * 2 * pi);
                return Transform.scale(scale: scale, child: child);
              },
              child: clockImage,
            ),
            const SizedBox(height: 30),
            // Fade and Slide transition for the "GeoWake" text.
            FadeTransition(
              opacity: CurvedAnimation(
                parent: textController,
                curve: Curves.easeInOut,
              ),
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.4), // Starts slightly below
                  end: Offset.zero, // Ends at its original position
                ).animate(
                  CurvedAnimation(
                    parent: textController,
                    curve: Curves.easeOut,
                  ),
                ),
                child: Text(
                  "GeoWake",
                  style: GoogleFonts.pacifico(
                    fontSize: 36,
                    color: scheme.onSurface,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
