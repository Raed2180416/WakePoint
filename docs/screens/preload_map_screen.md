# preload_map_screen.dart

- Transitional screen to warm up a GoogleMap instance before navigating to MapTracking.
- Reads `lat`/`lng` from arguments for initial camera; shows spinner until map is ready.
- On map created, schedules a short delay then navigates to `/mapTracking` with the same arguments.

# PreloadMapScreen (line-by-line)

Purpose: Warm the Google Map engine, then transition to `MapTrackingScreen` for smoother load.

State:
- Completer for controller; `_isMapReady` gate.

Build:
- GoogleMap with initial camera at provided `lat/lng` args; no myLocation or zoom controls.
- `onMapCreated`: completes controller, sets `_isMapReady`, logs, and after ~700 ms pushes replacement to `/mapTracking` passing the same arguments.
- Shows spinner overlay until map reports ready.
