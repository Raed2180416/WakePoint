# GeoWake

GeoWake is a smart, location-based wake-up app that makes your daily commute stress-free.
Imagine never missing your stop again—whether you're taking the metro or driving—because GeoWake monitors your journey in real time and alerts you just before you reach your destination.

## What It Solves

- **Missed Stops**: Automatically alerts you when you're approaching your chosen stop, whether it's by distance or time.
- **Ease-of-Use**: Set your destination and preferred alert (like "wake me 2 minutes before I reach my stop") and let the app do the rest.
- **Accurate Tracking**: Uses a combination of on-device GPS and smart API calls to deliver accurate predictions—even if you lose connectivity underground.
- **Battery Efficiency**: GeoWake smartly adjusts its location update frequency based on your battery level, ensuring minimal drain while you travel.

## How It Works (In Brief)

1. **Destination & Settings**: Enter your destination via an intuitive search interface. Choose whether you want an alert based on time (minutes) or distance (kilometers).
2. **Real-Time Monitoring**: The app continuously tracks your location and compares it to your planned route.
3. **Smart Alerts**: When you're about to reach your stop, GeoWake sends you a local notification—no need to constantly check the map.
4. **Offline Reliability**: Even if you lose connection (like underground), the app uses cached route data and on-device computations to keep you informed.

GeoWake makes your commute easier by letting you enjoy your journey, without the hassle of waking up too early or missing your stop.

---

## OSM Deviation Simulation Dashboard

A web-based visual testing tool for simulating and debugging route deviation, rerouting, and alarm logic.

### Features

| Feature | Description |
|---------|-------------|
| **OSM Street Overlay** | Full Bengaluru street network rendered on Google Maps |
| **Deviation Simulation** | A* pathfinding simulates user deviating AWAY from current route |
| **Return Simulation** | A* pathfinding simulates user returning to original route |
| **Time Warp** | Slider 1x-500x accelerates ALL time-dependent logic uniformly |
| **Speed Control** | Simulated movement speed from 1-160 km/h |
| **Constraint Log Drawer** | Real-time slide-out panel showing deviation events, reroute decisions, termination evaluations |
| **Multi-Route Display** | Gray inactive routes, orange deviation path, colored active route |

### Running the Dashboard

```bash
# Build and serve for web
flutter run -d chrome --web-port=8080

# Or build release
flutter build web
```

Then open your browser to the dashboard URL.

### Dashboard Controls

| Control | Function |
|---------|----------|
| **Start Deviation** | Begin A* pathfinding away from current route |
| **Stop Deviation** | Halt deviation simulation at current position |
| **Go Back to Old Route** | Begin A* pathfinding back to original route |
| **Time Warp Slider** | Adjust time multiplier (1x = real-time, 500x = fast-forward) |
| **Speed Slider** | Adjust simulated GPS movement speed |
| **Constraint Drawer Toggle** | Show/hide the real-time event log panel |

### Time Warp Scope

Time warp affects **ALL** time-dependent logic uniformly:

- Deviation detection and sustain duration
- Reroute cooldown periods
- Alarm cooldown and firing intervals
- ETA calculations
- Termination policy duration checks
- GPS check intervals
- All logged timestamps

### Architecture

```
+-------------------------------------------------------------------------+
|                           WEB DASHBOARD                                 |
|  +-------------+  +-------------+  +-------------+  +----------------+  |
|  |  Controls   |  |  Map View   |  | Constraint  |  |  Time Warp     |  |
|  |  Panel      |  |  (GMaps +   |  | Log Drawer  |  |  Controls      |  |
|  |             |  |   OSM)      |  |             |  |                |  |
|  +-------------+  +-------------+  +-------------+  +----------------+  |
+-------------------------------------------------------------------------+
                             | WebSocket
                             v
+-------------------------------------------------------------------------+
|                      APP SERVICES (via AppClock)                        |
|   TrackingService -> RouteSessionManager -> DeviationMonitor            |
|                   -> ReroutePolicy -> TerminationPolicy                 |
+-------------------------------------------------------------------------+
```

### Key Components

| Component | File | Purpose |
|-----------|------|---------|
| `DeviationDashboard` | `lib/dashboard/deviation_dashboard.dart` | Main dashboard widget with map, controls, and drawer |
| `DeviationSimulationController` | `lib/dashboard/deviation_simulation_controller.dart` | Orchestrates deviation simulation, pathfinding, WebSocket |
| `OsmOverlayManager` | `lib/dashboard/osm_overlay_manager.dart` | Manages OSM street polylines on Google Maps |
| `OsmGraph` | `lib/services/testing/osm_graph.dart` | Graph data structure for OSM nodes/edges |
| `Pathfinder` | `lib/services/testing/pathfinder.dart` | A* pathfinding engine |
| `AppClock` | `lib/core/clock/app_clock.dart` | Time abstraction supporting time warp |

### OSM Data Pipeline

1. **Preprocessing**: `tools/osm_preprocessor.py` converts `.osm.pbf` to optimized binary
2. **Loading**: `OsmDataLoader` efficiently loads graph from binary format
3. **Pathfinding**: `Pathfinder` uses A* with highway-type cost multipliers

### Testing

```bash
# Run all tests (445 tests)
flutter test

# Run dashboard-specific tests
flutter test test/dashboard/

# Run with coverage
flutter test --coverage
```

### Implementation Details

See [docs/osm_dashboard_implementation.md](docs/osm_dashboard_implementation.md) for comprehensive implementation reference including:

- Codebase audits (DateTime.now, Timer locations)
- AppClock abstraction design
- File-by-file modification plans
- State machine designs
- Phase-by-phase implementation checklist

---

## Development Setup

### Prerequisites

- Flutter SDK (3.x)
- Dart SDK
- Google Maps API key (for map features)
- Chrome (for web dashboard testing)

### Running Tests

```bash
# All tests
flutter test

# With coverage
flutter test --coverage

# Specific test file
flutter test test/path/to/test_file.dart
```

### Building

```bash
# Android APK (debug)
flutter build apk --debug

# Web
flutter build web

# Run on device
flutter run
```

---

## Project Structure

```
lib/
  core/
    clock/          # AppClock time abstraction
    logging/        # Logging utilities
  dashboard/        # OSM deviation simulation dashboard
  models/           # Data models
  services/         # Core services (tracking, routing, etc.)
    testing/        # OSM graph and pathfinding
    tracking/       # GPS tracking and alarm logic
  widgets/          # Reusable UI components
test/
  core/             # Core utility tests
  dashboard/        # Dashboard-specific tests
  services/         # Service tests
docs/
  osm_dashboard_implementation.md  # Implementation reference
tools/
  osm_preprocessor.py  # OSM data preprocessing
```

---

## License

Proprietary - All rights reserved.
