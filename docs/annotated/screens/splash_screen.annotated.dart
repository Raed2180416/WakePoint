// docs/annotated/screens/splash_screen.annotated.dart
// Purpose: Line-by-line annotated copy of `lib/screens/splash_screen.dart`.
// Scope: Animated splash with pulsing logo, delayed text fade/slide, timed navigation to HomeScreen.

import 'dart:async'; // Used for Future.delayed scheduling of animations and navigation.
import 'dart:math'; // Provides sin and pi for pulsing animation.
import 'package:flutter/material.dart'; // Flutter UI framework widgets and material design components.
import 'package:google_fonts/google_fonts.dart'; // Custom font loader for styled text.
import 'package:geowake2/screens/homescreen.dart'; // Package import ensures analyzer can resolve HomeScreen symbol.

class SplashScreen extends StatefulWidget { // Stateful widget to host animations that require Ticker.
  const SplashScreen({Key? key}) : super(key: key); // Const constructor with optional key.
  
  @override
  State<SplashScreen> createState() => _SplashScreenState(); // Creates associated state object.
}

class _SplashScreenState extends State<SplashScreen> with TickerProviderStateMixin { // State class; mixin provides vsync for animations.
  late AnimationController ringController; // Controls pulsing scale animation for the logo.
  late AnimationController textController; // Controls fade/slide for the "GeoWake" text.
  
  @override
  void initState() { // Lifecycle: initialize controllers and schedule transitions.
    super.initState(); // Call parent init.
    
    // Controller for the pulsing (ringing) effect. // 2s loop, reversible for smooth in/out.
    ringController = AnimationController(
      vsync: this, // Ticker from the state for frame callbacks.
      duration: const Duration(seconds: 2), // Full cycle duration.
    )..repeat(reverse: true); // Start repeating with reverse for oscillation.
    
    // Controller for the fade and slide in of the text. // Separate timeline.
    textController = AnimationController(
      vsync: this, // Same vsync provider.
      duration: const Duration(seconds: 2), // Transition duration.
    );
    
    // Start text animation slightly after the splash appears. // Delayed entrance for visual rhythm.
    Future.delayed(const Duration(milliseconds: 800), () {
      textController.forward(); // Animate text from 0.0 to 1.0 over 2s.
    });
    
    // Navigate to the HomeScreen after 3 seconds. // Timed auto-navigation.
    Future.delayed(const Duration(seconds: 3), () {
      Navigator.of(context).pushReplacement( // Replace splash so back button won't return to it.
        MaterialPageRoute(builder: (_) => const HomeScreen()), // Build target screen.
      );
    });
  }
  
  @override
  void dispose() { // Cleanup: dispose controllers to free Tickers and resources.
    ringController.dispose(); // Stop and dispose pulsing controller.
    textController.dispose(); // Stop and dispose text controller.
    super.dispose(); // Call parent dispose.
  }
  
  @override
  Widget build(BuildContext context) { // Build UI tree for the splash screen.
    // Load your custom clock logo image. // From assets declared in pubspec.yaml.
    final clockImage = Image.asset('assets/geowake.png', width: 150); // Fixed-size app logo.
    
    return Scaffold( // Page scaffold with background and body.
      backgroundColor: Colors.white, // Solid white backdrop.
      body: Center( // Center contents horizontally and vertically.
        child: Column( // Vertical stack of logo and text.
          mainAxisAlignment: MainAxisAlignment.center, // Center vertically within column.
          children: [ // Column children list.
            // AnimatedBuilder creates the pulsing effect. // Rebuilds transform on each tick.
            AnimatedBuilder(
              animation: ringController, // Listen to pulsing controller.
              builder: (context, child) { // Child: logo; builder composes scale.
                double scale = 1 + 0.05 * sin(ringController.value * 2 * pi); // Compute gentle +/-5% scale oscillation.
                return Transform.scale( // Apply scaling transform.
                  scale: scale, // Current scale.
                  child: child, // Use pre-built child for perf.
                );
              },
              child: clockImage, // Static logo used as child to avoid rebuilding image.
            ),
            const SizedBox(height: 30), // Spacing between logo and text.
            // Fade and Slide transition for the "GeoWake" text. // Coordinated opacity and position.
            FadeTransition(
              opacity: CurvedAnimation( // Wrap controller with easing curve.
                parent: textController, // Driver.
                curve: Curves.easeInOut, // Smooth opacity change.
              ),
              child: SlideTransition( // Animate vertical offset.
                position: Tween<Offset>( // Offsets in fractional units of the widget size.
                  begin: const Offset(0, 0.4), // Starts slightly below
                  end: Offset.zero,           // Ends at its original position
                ).animate(CurvedAnimation( // Apply ease-out motion curve.
                  parent: textController, // Driver shared with opacity.
                  curve: Curves.easeOut, // Faster at start, slows near end.
                )),
                child: Text( // App name label with custom font.
                  "GeoWake", // Displayed title.
                  style: GoogleFonts.pacifico( // Use Pacifico font.
                    fontSize: 36, // Large title size.
                    color: Colors.blueGrey[800], // Dark blue-grey tint.
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

// Post-block notes:
// - Two independent AnimationControllers: continuous pulsing for the logo, delayed one-shot for text.
// - `pushReplacement` removes splash from the back stack to avoid navigating back to it.
// - `AnimatedBuilder` uses `child` to avoid rebuilding the image each tick; improves performance.
// - All durations/offsets are tunable UX parameters.

// End-of-file summary:
// - Presents an animated splash then navigates to `HomeScreen` after ~3 seconds.
// - Uses TickerProviderStateMixin to drive animations; disposes cleanly to avoid leaks.
// - Assets: relies on `assets/geowake.png` configured in pubspec.
