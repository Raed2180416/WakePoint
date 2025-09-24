# SplashScreen

- Purpose: Branded entry screen with animated logo and title before transitioning to Home.
- Animations:
  - Ringing/pulsing scale animation on the logo via `AnimationController.repeat(reverse: true)` and `sin` function.
  - Fade and slide-in for the title using a separate `AnimationController`.
- Flow:
  - Starts text animation after 800 ms; navigates to `HomeScreen` after 3 seconds via `pushReplacement`.
