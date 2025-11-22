# GeoWake Frontend Documentation

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Technology Stack](#2-technology-stack)
3. [Project Structure](#3-project-structure)
4. [Flutter Framework & Web Platform](#4-flutter-framework--web-platform)
5. [Application Entry Point](#5-application-entry-point)
6. [Screens & Navigation](#6-screens--navigation)
7. [Services & Business Logic](#7-services--business-logic)
8. [State Management](#8-state-management)
9. [UI Components & Theming](#9-ui-components--theming)
10. [Data Flow & API Integration](#10-data-flow--api-integration)
11. [Location Tracking & Mapping](#11-location-tracking--mapping)
12. [Notification System](#12-notification-system)
13. [Background Services](#13-background-services)
14. [Configuration & Environment](#14-configuration--environment)
15. [Build & Deployment](#15-build--deployment)
16. [Dependencies](#16-dependencies)
17. [Best Practices](#17-best-practices)

---

## 1. Architecture Overview

GeoWake is a **location-based wake-up application** built using **Flutter**, a cross-platform framework that enables deployment to iOS, Android, Web, and Desktop platforms from a single codebase. The frontend implements a **service-oriented architecture** with clear separation of concerns.

### High-Level Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Flutter Application                       │
├─────────────────────────────────────────────────────────────┤
│  Presentation Layer                                          │
│  ├── Screens (HomeScreen, MapTracking, etc.)                │
│  ├── Widgets (PulsingDots, Custom UI Components)            │
│  └── Themes (Light/Dark Mode)                               │
├─────────────────────────────────────────────────────────────┤
│  Business Logic Layer                                        │
│  ├── TrackingService (Core location tracking)               │
│  ├── RouteManagement (ActiveRouteManager, RouteRegistry)    │
│  ├── NotificationService (Alarm & notifications)            │
│  ├── ApiClient (Secure API communication)                   │
│  └── OfflineCoordinator (Caching & offline mode)            │
├─────────────────────────────────────────────────────────────┤
│  Data Layer                                                  │
│  ├── Hive (Local NoSQL database)                            │
│  ├── SharedPreferences (Simple key-value storage)           │
│  └── RouteCache (Cached directions & polylines)             │
└─────────────────────────────────────────────────────────────┘
```

### Key Architectural Principles

1. **Separation of Concerns**: UI, business logic, and data layers are clearly separated
2. **Service Pattern**: Singleton services manage specific domains
3. **Reactive Programming**: Streams and listeners for real-time updates
4. **Offline-First**: Local caching with graceful degradation when offline
5. **Security-First**: API keys secured server-side
6. **Battery Optimization**: Adaptive location tracking
7. **Cross-Platform**: Single codebase for multiple platforms

---

## 2. Technology Stack

### Core Framework
- **Flutter 3.7+**: Google's UI toolkit for building natively compiled applications
- **Dart SDK 3.7+**: Programming language for Flutter
- **Material Design 3**: Modern Material You design system

### Key Dependencies
- **Google Maps Flutter 2.2.5**: Interactive map rendering
- **Geolocator 14.0.0**: GPS positioning and distance calculations
- **Hive 2.2.3**: Fast, lightweight NoSQL database
- **Flutter Background Service 5.0.5**: Long-running background tasks
- **Flutter Local Notifications 19.0.0**: Local push notifications
- **AudioPlayers 6.4.0**: Alarm sound playback
- **HTTP 1.4.0**: REST API communication
- **Google Fonts 6.2.1**: Custom typography (Pacifico, Montserrat)

---

## 3. Project Structure

```
lib/
├── main.dart                     # Application entry point
├── config/                       # Configuration files
│   ├── app_config.dart          # App-wide configuration
│   └── power_policy.dart        # Battery optimization policies
├── screens/                      # UI screens
│   ├── splash_screen.dart       # Initial splash screen
│   ├── homescreen.dart          # Main home screen
│   ├── maptracking.dart         # Active tracking screen
│   ├── alarm_fullscreen.dart    # Full-screen alarm
│   ├── ringtones_screen.dart    # Alarm sound selection
│   └── settingsdrawer.dart      # Settings drawer
├── services/                     # Business logic services
│   ├── trackingservice.dart     # Core location tracking
│   ├── api_client.dart          # Secure API communication
│   ├── notification_service.dart # Notifications & alarms
│   ├── active_route_manager.dart # Multi-route management
│   └── [20+ other services...]
├── models/                       # Data models
│   └── route_models.dart        # Route data structures
├── widgets/                      # Reusable UI components
│   └── pulsing_dots.dart        # Animated loading indicator
└── themes/                       # Visual themes
    └── appthemes.dart           # Light & dark theme definitions


---

## 4. Flutter Framework & Web Platform

### Flutter Overview

Flutter is Google's UI toolkit for building beautiful, natively compiled applications for mobile, web, and desktop from a single codebase. GeoWake leverages Flutter's core capabilities:

**Key Features:**
- **Hot Reload**: Instant updates during development
- **Widget-Based**: Everything is a widget (UI components)
- **Reactive Framework**: UI automatically updates when state changes
- **Platform Channels**: Native code integration for platform-specific features
- **Dart Language**: Fast, strongly-typed, object-oriented language

### Web Platform Configuration

#### **web/index.html**
The entry point for the web application. Key elements:

```html
<!DOCTYPE html>
<html>
<head>
  <base href="$FLUTTER_BASE_HREF">
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>geowake2</title>
  <link rel="manifest" href="manifest.json">
  <link rel="icon" type="image/png" href="favicon.png">
</head>
<body>
  <picture id="splash">
    <!-- Responsive splash images for light/dark mode -->
  </picture>
  <script src="flutter_bootstrap.js" async=""></script>
</body>
</html>
```

**Features:**
- **Splash Screen**: Custom splash images for light and dark modes
- **PWA Support**: Progressive Web App manifest
- **Responsive Design**: Viewport meta tag for mobile compatibility
- **Bootstrap Loading**: Asynchronous Flutter framework loading

#### **web/manifest.json**
Progressive Web App (PWA) configuration:

```json
{
  "name": "geowake2",
  "short_name": "geowake2",
  "start_url": ".",
  "display": "standalone",
  "background_color": "#0175C2",
  "theme_color": "#0175C2",
  "description": "A new Flutter project.",
  "orientation": "portrait-primary",
  "icons": [
    { "src": "icons/Icon-192.png", "sizes": "192x192", "type": "image/png" },
    { "src": "icons/Icon-512.png", "sizes": "512x512", "type": "image/png" }
  ]
}
```

**PWA Capabilities:**
- **Installable**: Can be installed as a native app
- **Offline Support**: Service worker caching
- **Full-Screen Mode**: Standalone display removes browser UI
- **App-Like Experience**: Custom theme colors and icons

---

## 5. Application Entry Point

### **lib/main.dart**

The entry point of the Flutter application. This file initializes all essential services and bootstraps the app.

#### Main Function

```dart
Future<void> main() async {
  // Ensure Flutter binding is initialized
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize Hive (local database)
  await Hive.initFlutter();
  
  // Initialize essential services
  await _initializeServices();
  
  // Run the app
  runApp(const MyApp());
}
```

**Initialization Sequence:**
1. **Flutter Bindings**: Ensures Flutter framework is ready
2. **Hive Database**: Initializes local NoSQL storage
3. **Services**: Starts API client, notifications, tracking service
4. **Dev Server**: Launches debug HTTP server in debug/profile mode
5. **App Launch**: Creates the root widget tree

#### Service Initialization

```dart
Future<void> _initializeServices() async {
  // API Client - FIRST for security
  await ApiClient.instance.initialize();
  
  // Notification Service
  await NotificationService().initialize();
  
  // Tracking Service
  await TrackingService().initializeService();
  
  // Dev Server (debug/profile only)
  if (kDebugMode || kProfileMode) {
    DevServer.start();
  }
}
```

**Critical Order:**
- ApiClient must initialize first to secure all API calls
- NotificationService needed for alarm functionality
- TrackingService depends on other services

#### MyApp Widget

```dart
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
    // Listen for app lifecycle events
    WidgetsBinding.instance.addObserver(this);
    
    // Check notification permission
    _checkNotificationPermission();
    
    // Show pending alarms if any
    NotificationService().showPendingAlarmScreenIfAny();
    
    // Bridge background alarm events to foreground
    FlutterBackgroundService().on('fireAlarm').listen((event) {
      // Handle alarm from background service
      NotificationService().showWakeUpAlarm(/*...*/);
    });
  }
}
```

**Key Responsibilities:**
- **Lifecycle Management**: Monitors app state (paused, resumed, inactive)
- **Permission Handling**: Ensures notification permissions are granted
- **Alarm Bridging**: Connects background service alarms to UI
- **Theme Management**: Provides light/dark mode toggle
- **Data Persistence**: Flushes Hive database when app is paused

#### App Lifecycle Management

```dart
@override
void didChangeAppLifecycleState(AppLifecycleState state) {
  super.didChangeAppLifecycleState(state);
  
  if (state == AppLifecycleState.paused) {
    // App going to background - flush data to disk
    if (Hive.isBoxOpen(RecentLocationsService.boxName)) {
      Hive.box(RecentLocationsService.boxName).flush();
    }
  }
  
  if (state == AppLifecycleState.resumed) {
    // App returning to foreground - show pending alarms
    NotificationService().showPendingAlarmScreenIfAny();
  }
}
```

**Lifecycle States:**
- **Paused**: App in background, save critical data
- **Resumed**: App in foreground, restore UI state
- **Inactive**: Transitioning between states
- **Detached**: App about to terminate

#### Navigation Configuration

```dart
@override
Widget build(BuildContext context) {
  return MaterialApp(
    title: 'GeoWake',
    navigatorKey: NavigationService.navigatorKey,
    theme: isDarkMode ? AppThemes.darkTheme : AppThemes.lightTheme,
    initialRoute: '/splash',
    onGenerateRoute: (settings) {
      if (settings.name == '/splash') {
        return MaterialPageRoute(builder: (_) => const SplashScreen());
      }
      if (settings.name == '/preloadMap') {
        final args = settings.arguments as Map<String, dynamic>;
        return MaterialPageRoute(
          builder: (_) => PreloadMapScreen(arguments: args)
        );
      }
      if (settings.name == '/mapTracking') {
        return MaterialPageRoute(builder: (_) => MapTrackingScreen());
      }
      if (settings.name == '/') {
        return MaterialPageRoute(builder: (_) => const HomeScreen());
      }
      return null;
    },
  );
}
```

**Routes:**
- `/splash` → SplashScreen (initial route)
- `/` → HomeScreen (main screen)
- `/preloadMap` → PreloadMapScreen (route loading)
- `/mapTracking` → MapTrackingScreen (active tracking)

---

## 6. Screens & Navigation

### Navigation Flow

```
┌─────────────┐
│ SplashScreen│ (3 seconds)
└──────┬──────┘
       │
       ▼
┌─────────────┐     "Wake Me" button    ┌──────────────┐
│ HomeScreen  │ ──────────────────────→ │ PreloadMap   │
│             │                          │ Screen       │
└─────────────┘                          └──────┬───────┘
       ▲                                        │
       │                                        ▼
       │                                ┌──────────────┐
       │      "End Tracking" button     │ MapTracking  │
       └────────────────────────────────│ Screen       │
                                        └──────────────┘
```

### Screen Details

#### 1. **SplashScreen** (`lib/screens/splash_screen.dart`)

**Purpose**: Branded loading screen shown during app initialization

**Features:**
- **Animated Logo**: Pulsing clock animation using `AnimationController`
- **Fade-In Text**: "GeoWake" text with slide transition
- **Auto-Navigation**: Automatically navigates to HomeScreen after 3 seconds
- **Brand Identity**: Uses Pacifico font for consistent branding

**Implementation Highlights:**
```dart
class _SplashScreenState extends State<SplashScreen> 
    with TickerProviderStateMixin {
  late AnimationController ringController;
  late AnimationController textController;
  
  @override
  void initState() {
    super.initState();
    
    // Pulsing animation (loops forever)
    ringController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
    
    // Text fade-in after 800ms
    textController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );
    Timer(const Duration(milliseconds: 800), () {
      textController.forward();
    });
    
    // Navigate to HomeScreen after 3 seconds
    Timer(const Duration(seconds: 3), () {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const HomeScreen()),
      );
    });
  }
}
```

**Assets Used:**
- `assets/geowake.png` - App logo image

---

#### 2. **HomeScreen** (`lib/screens/homescreen.dart`)

**Purpose**: Main interface for setting destination and configuring wake-up alarm

**Features:**
- **Destination Search**: Google Places autocomplete with recent locations
- **Interactive Map**: Google Maps widget with tap-to-select location
- **Mode Selection**: Toggle between time/distance/stops-based alerts
- **Metro Mode**: Special mode for public transit with stop-based alerts
- **Slider Configuration**: Adjust alert threshold (km, minutes, or stops)
- **Battery & Connectivity Indicators**: Shows offline mode and low battery warnings
- **Settings Drawer**: Access to app settings and theme toggle

**State Management:**
```dart
class HomeScreenState extends State<HomeScreen> {
  // Search & Location
  final TextEditingController _searchController = TextEditingController();
  List<Map<String, dynamic>> _recentLocations = [];
  List<Map<String, dynamic>> _autocompleteResults = [];
  Map<String, dynamic>? _selectedLocation;
  LatLng? _currentPosition;
  
  // Configuration
  bool _useDistanceMode = true;    // true = distance, false = time
  bool _metroMode = false;         // true = metro mode, false = regular
  double _distanceSliderValue = 5.0;  // kilometers
  double _timeSliderValue = 15.0;     // minutes
  double _stopsSliderValue = 2.0;      // metro stops
  
  // UI State
  bool _isLoading = false;
  bool _isTracking = false;
  bool _noConnectivity = false;
  bool _lowBattery = false;
  
  // Map
  Set<Marker> _markers = {};
  final Completer<GoogleMapController> _mapController = Completer();
}
```

**Key Workflows:**

**A. Destination Search**
```dart
void _onSearchChanged(String query) {
  // Debounce search (450ms delay)
  _debounce = Timer(const Duration(milliseconds: 450), () async {
    // 1. Search recent locations locally
    final localMatches = _recentLocations.where((loc) =>
      loc['description'].toLowerCase().contains(query.toLowerCase())
    );
    
    // 2. Fetch from Google Places API via secure server
    final remoteResults = await _placesService.fetchAutocompleteResults(
      query,
      countryCode: _currentCountryCode,
      lat: _currentPosition?.latitude,
      lng: _currentPosition?.longitude,
    );
    
    // 3. Combine and deduplicate results
    final combined = [...localMatches];
    for (var remote in remoteResults) {
      if (!combined.any((local) => local['place_id'] == remote['place_id'])) {
        combined.add(remote);
      }
    }
    
    setState(() => _autocompleteResults = combined);
  });
}
```

**B. Map Interaction**
```dart
Future<void> _handleMapTap(LatLng position) async {
  final now = DateTime.now();
  final isDoubleTab = _lastTapAt != null && 
      now.difference(_lastTapAt!).inMilliseconds < 300;
  
  if (isDoubleTap) {
    // Zoom in on double-tap
    final controller = await _mapController.future;
    controller.animateCamera(
      CameraUpdate.newLatLngZoom(position, _lastZoom + 1.0)
    );
  } else {
    // Set destination on single-tap (debounced)
    _tapTimer = Timer(const Duration(milliseconds: 280), () async {
      await _setDestinationFromLatLng(position);
    });
  }
}
```

**C. Starting Tracking**
```dart
Future<void> _onWakeMePressed() async {
  // 1. Validate destination
  if (_selectedLocation == null) {
    _showErrorDialog("Destination Missing", "Please select a valid destination.");
    return;
  }
  
  // 2. Request permissions (location, notification, background)
  final permissionService = PermissionService(context);
  final canProceed = await permissionService.requestEssentialPermissions();
  if (!canProceed) return;
  
  // 3. Get current location
  final Position? currentPosition = await _getCurrentLocation();
  if (currentPosition == null) {
    _showErrorDialog("Location Error", "Could not get your current location.");
    return;
  }
  
  // 4. Validate metro route (if metro mode)
  if (_metroMode) {
    final validationResult = await MetroStopService.validateMetroRoute(
      startLocation: LatLng(currentPosition.latitude, currentPosition.longitude),
      destination: LatLng(destLat, destLng),
    );
    if (!validationResult.isValid) {
      _showErrorDialog("Metro Route Unavailable", validationResult.errorMessage);
      return;
    }
  }
  
  // 5. Fetch directions from API
  final directions = await _fetchDirections(userLat, userLng, destLat, destLng);
  
  // 6. Register route with TrackingService
  trackingService.registerRouteFromDirections(
    directions: directions,
    origin: LatLng(userLat, userLng),
    destination: LatLng(destLat, destLng),
    transitMode: _metroMode,
    destinationName: _selectedLocation['description'],
  );
  
  // 7. Start tracking
  await trackingService.startTracking(
    destination: LatLng(destLat, destLng),
    destinationName: _selectedLocation['description'],
    alarmMode: alarmMode,  // 'distance', 'time', or 'stops'
    alarmValue: alarmValue, // threshold value
  );
  
  // 8. Navigate to map tracking screen
  Navigator.pushReplacementNamed(context, '/preloadMap', arguments: mapArgs);
}
```

**UI Components:**
- **Search Bar**: Material TextField with autocomplete dropdown
- **Google Map**: Interactive map with current location and destination markers
- **Mode Toggles**: Time/Distance switch, Metro Mode switch
- **Slider**: Adjust alert threshold (responsive to mode selection)
- **Wake Me Button**: Primary action button (enabled only when destination is set)
- **Status Indicators**: Offline banner, low battery alert

---

#### 3. **PreloadMapScreen** (`lib/screens/otherimpservices/preload_map_screen.dart`)

**Purpose**: Intermediate loading screen while preparing map and route data

**Features:**
- **Progress Indicator**: Shows loading state
- **Route Preparation**: Decodes and simplifies polylines
- **Map Preloading**: Warms up Google Maps cache
- **Auto-Navigation**: Automatically proceeds to MapTrackingScreen when ready

**Flow:**
1. Receive route data from HomeScreen
2. Decode and optimize polyline
3. Preload map tiles for route area
4. Navigate to MapTrackingScreen with prepared data

---

#### 4. **MapTrackingScreen** (`lib/screens/maptracking.dart`)

**Purpose**: Real-time tracking display showing route progress and ETA

**Features:**
- **Live Map**: Google Maps with current location and destination
- **Route Visualization**: Colored polylines for different travel modes
  - Blue solid: Driving segments
  - Blue dashed: Walking segments
  - Green/Purple solid: Metro lines (Line A/B)
- **Real-Time Metrics**: ETA and distance to destination
- **Transfer Alerts**: Warnings for upcoming metro transfers
- **Route Snapping**: Aligns GPS position to actual route
- **Stop Alarm Button**: Silences alarm when it fires
- **End Tracking Button**: Stops tracking and returns to HomeScreen

**State Management:**
```dart
class _MapTrackingScreenState extends State<MapTrackingScreen> {
  // Map & Route
  final Completer<GoogleMapController> _mapController = Completer();
  Set<Marker> _markers = {};
  Set<Polyline> _polylines = {};
  List<LatLng> _routePoints = [];
  
  // Tracking State
  LatLng? _currentUserLocation;
  double _routeLengthMeters = 0.0;
  double? _speedEmaMps;  // Exponential moving average speed
  int? _lastSnapIndex;    // Last snapped polyline segment
  
  // Display
  String _etaText = "Calculating ETA...";
  String _distanceText = "Calculating distance...";
  String? _switchNotice;  // Transfer warning message
  
  // Subscriptions
  StreamSubscription<Position>? _locationSubscription;
  StreamSubscription<RouteSwitchEvent>? _routeSwitchSub;
  StreamSubscription<ActiveRouteState>? _routeStateSub;
}
```

**Real-Time Updates:**
```dart
void _startLocationUpdates() {
  // High accuracy GPS updates every 5 meters
  _locationSubscription = Geolocator.getPositionStream(
    locationSettings: const LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 5,
    )
  ).listen((position) {
    // Update current location
    _currentUserLocation = LatLng(position.latitude, position.longitude);
    
    // Snap to route for accuracy
    final snap = SnapToRouteEngine.snap(
      point: _currentUserLocation!,
      polyline: _routePoints,
      hintIndex: _lastSnapIndex,
      searchWindow: 30,
    );
    
    // Calculate remaining distance
    final progress = snap.progressMeters;
    final remaining = (_routeLengthMeters - progress).clamp(0.0, double.infinity);
    
    // Calculate ETA from step durations
    final etaSec = EtaUtils.etaRemainingSeconds(
      progressMeters: progress,
      stepBoundariesMeters: _stepBoundariesMeters,
      stepDurationsSeconds: _stepDurationsSeconds,
    ) ?? (remaining / 12.0);  // Fallback: 43 km/h average
    
    // Update UI
    setState(() {
      _etaText = _formatEta(etaSec);
      _distanceText = _formatDistance(remaining);
      _updateMarker(snap.snappedPoint);
    });
  });
}
```

**Route Visualization:**
```dart
Set<Polyline> _buildSegmentedPolylines(Map<String, dynamic> directions) {
  final Set<Polyline> polylines = {};
  final routes = directions['routes'] as List;
  
  for (final route in routes) {
    final legs = route['legs'] as List;
    for (final leg in legs) {
      final steps = leg['steps'] as List;
      
      for (int i = 0; i < steps.length; i++) {
        final step = steps[i];
        final travelMode = step['travel_mode'];
        final polyline = decodePolyline(step['polyline']['points']);
        
        // Determine color based on travel mode
        Color color;
        bool dashed = false;
        
        if (travelMode == 'WALKING') {
          color = Colors.blue;
          dashed = true;
        } else if (travelMode == 'TRANSIT') {
          final transitDetails = step['transit_details'];
          final line = transitDetails['line'];
          color = _getMetroLineColor(line['short_name']);
        } else {
          color = Colors.blue;  // DRIVING
        }
        
        polylines.add(Polyline(
          polylineId: PolylineId('step_$i'),
          points: polyline,
          color: color,
          width: 4,
          patterns: dashed ? [PatternItem.dash(10), PatternItem.gap(10)] : [],
        ));
      }
    }
  }
  
  return polylines;
}
```

**UI Layout:**
```
┌──────────────────────────────────────┐
│  AppBar: "Map Tracking" + Settings   │
├──────────────────────────────────────┤
│                                       │
│         Google Maps View              │
│  (with polylines, markers, legend)    │
│                                       │
├──────────────────────────────────────┤
│  ETA: "5 min remaining"               │
│  Distance: "2.3 km to destination"    │
│  Transfer: "Switch in 2 min" (if any)│
├──────────────────────────────────────┤
│  [STOP ALARM]  [END TRACKING]        │
├──────────────────────────────────────┤
│  Ad Banner Placeholder                │
└──────────────────────────────────────┘
```

---

#### 5. **AlarmFullScreen** (`lib/screens/alarm_fullscreen.dart`)

**Purpose**: Full-screen alarm notification when approaching destination

**Features:**
- **Full-Screen Display**: Covers entire screen to get attention
- **Alarm Sound**: Plays selected ringtone with vibration
- **Wake Up Message**: Clear, large text indicating arrival
- **Action Buttons**: 
  - "Stop Alarm": Silence alarm
  - "Continue Tracking": Resume tracking with alarm silenced
- **Auto-Dismiss**: Can be configured to auto-dismiss after timeout

**Trigger**: Launched by NotificationService when alarm threshold is reached

---

#### 6. **RingtonesScreen** (`lib/screens/ringtones_screen.dart`)

**Purpose**: Allow users to select custom alarm sound

**Features:**
- **Ringtone List**: Displays available alarm sounds
- **Preview Playback**: Tap to play sample
- **Selection**: Save preferred ringtone to SharedPreferences
- **Default Ringtone**: Fallback if custom sound unavailable

**Assets**: Stores audio files in `assets/ringtones/`

---

#### 7. **SettingsDrawer** (`lib/screens/settingsdrawer.dart`)

**Purpose**: Side drawer for app settings and configuration

**Options:**
- **Theme Toggle**: Switch between light and dark mode
- **Alarm Ringtones**: Navigate to ringtone selection
- **Go Premium**: Purchase premium features (ads removal)
- **Close**: Dismiss drawer

**Implementation:**
```dart
class SettingsDrawer extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final appState = context.findAncestorStateOfType<MyAppState>();
    final isDarkMode = appState?.isDarkMode ?? false;
    
    return Drawer(
      child: ListView(
        children: [
          DrawerHeader(
            decoration: BoxDecoration(color: Colors.deepPurple),
            child: Text('Settings', style: TextStyle(fontSize: 24)),
          ),
          ListTile(
            leading: Icon(isDarkMode ? Icons.wb_sunny : Icons.nightlight_round),
            title: Text(isDarkMode ? 'Light Mode' : 'Dark Mode'),
            onTap: () {
              appState?.toggleTheme();
              Navigator.pop(context);
            },
          ),
          ListTile(
            leading: Icon(Icons.alarm),
            title: Text('Alarm Ringtones'),
            onTap: () {
              Navigator.pop(context);
              Navigator.push(context, MaterialPageRoute(
                builder: (_) => const RingtonesScreen(),
              ));
            },
          ),
          ListTile(
            leading: Icon(Icons.star),
            title: Text('Go Premium'),
            onTap: () {
              // TODO: Implement in-app purchase
            },
          ),
        ],
      ),
    );
  }
}
```

---

## 7. Services & Business Logic

GeoWake implements a **service-oriented architecture** where each service is a singleton managing a specific domain. Services communicate via streams and callbacks.

### Service Categories

```
Services (25+ files)
├── Core Tracking
│   ├── TrackingService          # Main tracking orchestrator
│   ├── ActiveRouteManager        # Multi-route handling
│   └── RouteRegistry             # Route storage & lookup
├── Location & Navigation
│   ├── DirectionService          # Route directions
│   ├── PlacesService             # Google Places API
│   ├── MetroStopService          # Metro station detection
│   ├── SnapToRoute               # Position correction
│   └── SensorFusion              # GPS + accelerometer fusion
├── Route Management
│   ├── RouteCache                # Offline route storage
│   ├── RouteQueue                # Request queuing
│   ├── OfflineCoordinator        # Offline mode manager
│   ├── PolylineDecoder           # Decode Google polylines
│   └── PolylineSimplifier        # Optimize polylines
├── Tracking Intelligence
│   ├── DeviationDetection        # Off-route detection
│   ├── DeviationMonitor          # Continuous monitoring
│   ├── ReroutePolicy             # Reroute decision logic
│   ├── EtaUtils                  # ETA calculations
│   └── TransferUtils             # Transit transfer detection
├── Notifications & Alarms
│   ├── NotificationService       # Push notifications
│   └── AlarmPlayer               # Alarm sound playback
├── Infrastructure
│   ├── ApiClient                 # Secure API communication
│   ├── PermissionService         # Runtime permissions
│   └── NavigationService         # Global navigation
└── Configuration
    └── PowerPolicy               # Battery optimization
```

---

### Key Services Detailed

#### 1. **TrackingService** (`lib/services/trackingservice.dart`)

**Purpose**: Core service orchestrating all location tracking functionality

**Responsibilities:**
- Initialize and manage background service
- Start/stop tracking sessions
- Monitor GPS position continuously
- Calculate distance to destination
- Trigger alarms based on thresholds
- Handle offline mode gracefully
- Adjust tracking frequency based on battery

**Public API:**
```dart
class TrackingService {
  // Singleton
  static final TrackingService _instance = TrackingService._internal();
  factory TrackingService() => _instance;
  
  // Initialize service
  Future<void> initializeService();
  
  // Start tracking
  Future<void> startTracking({
    required LatLng destination,
    required String destinationName,
    required String alarmMode,     // 'distance', 'time', 'stops'
    required double alarmValue,
  });
  
  // Stop tracking
  Future<void> stopTracking();
  
  // Register route for multi-route tracking
  void registerRouteFromDirections({
    required Map<String, dynamic> directions,
    required LatLng origin,
    required LatLng destination,
    required bool transitMode,
    required String destinationName,
  });
  
  // Update connectivity status
  void setOnline(bool isOnline);
  
  // Streams
  Stream<ActiveRouteState> get activeRouteStateStream;
  Stream<RouteSwitchEvent> get routeSwitchStream;
  Stream<RerouteDecision> get rerouteDecisionStream;
}
```

**Tracking Algorithm:**
```dart
void _startLocationTracking() {
  // Determine update frequency based on battery
  final batteryLevel = await Battery().batteryLevel;
  final policy = PowerPolicy.getPolicy(batteryLevel);
  
  // Configure location settings
  final settings = LocationSettings(
    accuracy: policy.accuracy,
    distanceFilter: policy.distanceFilter,
  );
  
  // Start listening to GPS
  _locationSubscription = Geolocator.getPositionStream(
    locationSettings: settings
  ).listen((position) async {
    // 1. Snap position to route
    final snapped = _snapToRoute(position);
    
    // 2. Calculate remaining distance
    final remaining = _calculateRemaining(snapped);
    
    // 3. Check if alarm should fire
    if (_shouldFireAlarm(remaining)) {
      await _fireAlarm();
    }
    
    // 4. Check for deviation
    if (_isOffRoute(snapped)) {
      await _handleDeviation();
    }
    
    // 5. Update UI
    _broadcastState(remaining, _calculateETA(remaining));
  });
}

bool _shouldFireAlarm(double remainingMeters) {
  switch (alarmMode) {
    case 'distance':
      return remainingMeters <= (alarmValue * 1000);  // km to meters
    case 'time':
      final eta = _calculateETA(remainingMeters);
      return eta <= (alarmValue * 60);  // minutes to seconds
    case 'stops':
      final stops = _calculateRemainingStops(remainingMeters);
      return stops <= alarmValue;
    default:
      return false;
  }
}
```

**Background Service Integration:**
```dart
// Background service entry point (runs in isolate)
@pragma('vm:entry-point')
static void _onStart(ServiceInstance service) async {
  // Initialize in background isolate
  await Hive.initFlutter();
  await NotificationService().initialize();
  
  // Listen for commands from UI
  service.on('startTracking').listen((args) {
    _startBackgroundTracking(args);
  });
  
  service.on('stopTracking').listen((_) {
    _stopBackgroundTracking();
  });
  
  // Continuously update notification
  Timer.periodic(Duration(seconds: 1), (timer) {
    service.invoke('updateNotification', {
      'title': 'Tracking Active',
      'content': 'Distance: ${_formatDistance(remaining)}',
    });
  });
}
```

---

#### 2. **ApiClient** (`lib/services/api_client.dart`)

**Purpose**: Secure communication with backend server for Google Maps API calls

**Security Features:**
- **API Key Protection**: Keys stored server-side only
- **Token-Based Auth**: JWT authentication for all requests
- **HTTPS Only**: Encrypted communication
- **Request Signing**: Prevents tampering
- **Rate Limiting**: Prevents abuse

**Public API:**
```dart
class ApiClient {
  static ApiClient get instance;
  
  // Initialize and authenticate
  Future<void> initialize();
  
  // Test server connection
  Future<void> testConnection();
  
  // Google Places Autocomplete
  Future<List<Map<String, dynamic>>> autocomplete({
    required String input,
    String? sessionToken,
    String? country,
    double? lat,
    double? lng,
  });
  
  // Get place details
  Future<Map<String, dynamic>?> placeDetails({
    required String placeId,
    String? sessionToken,
  });
  
  // Get directions
  Future<Map<String, dynamic>> directions({
    required String origin,
    required String destination,
    String? mode,  // 'driving', 'walking', 'transit'
    bool alternatives = false,
  });
  
  // Reverse geocode (lat/lng to address)
  Future<Map<String, dynamic>?> geocode({
    required String latlng,
  });
}
```

**Authentication Flow:**
```dart
Future<void> _authenticate() async {
  // Request token from server
  final response = await http.post(
    Uri.parse('$_baseUrl/auth/token'),
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode({
      'bundleId': 'com.yourcompany.geowake2',
    }),
  );
  
  if (response.statusCode == 200) {
    final data = jsonDecode(response.body);
    _authToken = data['token'];
    _deviceId = data['deviceId'];
    _tokenExpiration = DateTime.parse(data['expiresAt']);
    
    // Save to persistent storage
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, _authToken!);
    await prefs.setString(_deviceIdKey, _deviceId!);
    await prefs.setString('${_tokenKey}_exp', _tokenExpiration!.toIso8601String());
  }
}

Future<Map<String, dynamic>> _makeRequest(String endpoint, Map<String, dynamic> body) async {
  // Ensure token is valid
  if (_isTokenExpired()) {
    await _authenticate();
  }
  
  // Make authenticated request
  final response = await http.post(
    Uri.parse('$_baseUrl/$endpoint'),
    headers: {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $_authToken',
      'X-Device-ID': _deviceId!,
    },
    body: jsonEncode(body),
  );
  
  if (response.statusCode == 401) {
    // Token expired, re-authenticate
    await _authenticate();
    return _makeRequest(endpoint, body);  // Retry
  }
  
  return jsonDecode(response.body);
}
```

---


#### 3. **NotificationService** (`lib/services/notification_service.dart`)

**Purpose**: Manages all notifications and alarms

**Features:**
- Local push notifications
- Full-screen alarm display
- Persistent journey progress notifications
- Wake-up alarm with sound and vibration
- Notification channels for Android

**Key Methods:**


---

#### 4. **ActiveRouteManager** (`lib/services/active_route_manager.dart`)

**Purpose**: Manages multiple transit routes (for metro mode with transfers)

**Features:**
- Track multiple route segments
- Automatic route switching at transfers
- Calculate remaining distance on active segment
- Predict upcoming transfers

---

#### 5. **OfflineCoordinator** (`lib/services/offline_coordinator.dart`)

**Purpose**: Handles offline mode and route caching

**Features:**
- Cache route directions locally
- Serve cached routes when offline
- Monitor connectivity status
- Fallback gracefully when no cache available

**Cache Strategy:**


---

## 8. State Management

GeoWake uses **built-in Flutter state management** patterns rather than third-party libraries like Provider or Riverpod. This keeps the codebase simple and reduces dependencies.

### State Management Patterns

#### 1. **StatefulWidget**
Primary pattern for screen-level state:



#### 2. **StreamController**
For reactive data flow between services and UI:



#### 3. **ValueNotifier**
Lightweight observable for simple state:



#### 4. **WidgetsBindingObserver**
For app lifecycle events:



---

## 9. UI Components & Theming

### Theme System

GeoWake implements Material Design 3 with custom light and dark themes.

#### **AppThemes** (`lib/themes/appthemes.dart`)



**Typography:**
- **App Name**: Pacifico (playful, branded)
- **Body Text**: Montserrat (clean, readable)

**Color Scheme:**
- **Primary**: Deep Purple
- **Light Background**: White (#FFFFFF)
- **Dark Background**: Dark Grey (#303030)

### Custom Widgets

#### **PulsingDots** (`lib/widgets/pulsing_dots.dart`)

Animated loading indicator used to show calculation in progress.



**Usage:**


---

## 10. Data Flow & API Integration

### Data Flow Architecture



### API Integration Examples

#### **Place Autocomplete**



#### **Directions Request**



---

## 11. Location Tracking & Mapping

### GPS & Location Services

#### **Geolocator Integration**



#### **Battery-Aware Tracking**



### Google Maps Integration

#### **Map Initialization**



#### **Polyline Rendering**



#### **Snap to Route**



---

## 12. Notification System

### Android Notification Channels



### Notification Types

#### 1. **Journey Progress** (Persistent)
Shows ongoing tracking status:



#### 2. **Wake Up Alarm** (Full-Screen)
Critical alarm when destination is near:



---

## 13. Background Services

### Flutter Background Service

GeoWake uses `flutter_background_service` to continue tracking when the app is backgrounded.

#### **Service Configuration**



#### **Background Isolate**

The background service runs in a separate Dart isolate:



#### **Foreground-Background Communication**



---

## 14. Configuration & Environment

### App Configuration

#### **app_config.dart**



### Power Policy Configuration



---

## 15. Build & Deployment

### Build Commands

#### **Web**
```bash
# Development
flutter run -d chrome

# Production build
flutter build web --release
```

#### **Android**
```bash
# Development
flutter run

# Release APK
flutter build apk --release

# Release App Bundle (for Play Store)
flutter build appbundle --release
```

#### **iOS**
```bash
# Development
flutter run -d ios

# Release
flutter build ios --release
```

### Pre-Build Steps

1. **Generate Splash Screens:**
```bash
flutter pub run flutter_native_splash:create
```

2. **Generate App Icons:**
```bash
flutter pub run flutter_launcher_icons:main
```

3. **Run Tests:**
```bash
flutter test
```

### Deployment Platforms

- **Web**: Static hosting (Firebase Hosting, Netlify, Vercel)
- **Android**: Google Play Store
- **iOS**: Apple App Store
- **Desktop**: Direct download or Microsoft Store / Mac App Store

---

## 16. Dependencies

### Core Dependencies

```yaml
dependencies:
  flutter:
    sdk: flutter
  
  # UI & Fonts
  cupertino_icons: ^1.0.8
  google_fonts: ^6.2.1
  
  # Location & Maps
  geolocator: ^14.0.0
  google_maps_flutter: ^2.2.5
  google_places_flutter: ^2.0.0
  
  # Data Persistence
  hive: ^2.2.3
  hive_flutter: ^1.1.0
  shared_preferences: ^2.2.3
  path_provider: ^2.1.1
  
  # Background Processing
  flutter_background_service: ^5.0.5
  flutter_background_service_android: ^6.2.2
  
  # Notifications & Audio
  flutter_local_notifications: ^19.0.0
  audioplayers: ^6.4.0
  
  # Sensors & Device
  sensors_plus: ^7.0.0
  battery_plus: ^7.0.0
  connectivity_plus: ^7.0.0
  device_info_plus: ^12.1.0
  
  # Permissions
  permission_handler: ^12.0.0
  app_settings: ^6.1.1
  
  # Networking
  http: ^1.4.0
  
  # Utilities
  logging: ^1.0.2
  flutter_dotenv: ^6.0.0
  android_intent_plus: ^6.0.0
  package_info_plus: ^9.0.0
  
  # Monetization
  google_mobile_ads: ^6.0.0
  in_app_purchase: ^3.2.1
```

### Dev Dependencies

```yaml
dev_dependencies:
  flutter_test:
    sdk: flutter
  integration_test:
    sdk: flutter
  
  # Code Quality
  flutter_lints: ^5.0.0
  meta: ^1.12.0
  
  # Build Tools
  flutter_native_splash: ^2.3.5
  flutter_launcher_icons: ^0.14.3
```

---

## 17. Best Practices

### Code Organization
- ✅ Separate concerns: screens, services, models, widgets
- ✅ Use descriptive file and class names
- ✅ Keep files focused (single responsibility)
- ✅ Group related functionality in directories

### State Management
- ✅ Use StatefulWidget for local UI state
- ✅ Use StreamController for reactive cross-component state
- ✅ Use ValueNotifier for simple observable values
- ✅ Dispose streams and controllers properly

### Performance
- ✅ Use const constructors where possible
- ✅ Avoid rebuilding entire widget trees
- ✅ Simplify polylines before rendering
- ✅ Cache network responses
- ✅ Optimize GPS update frequency based on battery

### Security
- ✅ Never expose API keys in client code
- ✅ Use authenticated API requests
- ✅ Validate and sanitize user input
- ✅ Handle errors gracefully without leaking sensitive info

### Error Handling
- ✅ Always handle async errors with try-catch
- ✅ Provide user-friendly error messages
- ✅ Log errors for debugging (using dart:developer)
- ✅ Fallback gracefully when services unavailable

### Testing
- ✅ Write unit tests for business logic
- ✅ Write widget tests for UI components
- ✅ Write integration tests for critical flows
- ✅ Mock external dependencies in tests

### Accessibility
- ✅ Use semantic labels for screen readers
- ✅ Ensure sufficient color contrast
- ✅ Support text scaling
- ✅ Keyboard navigation where applicable

---

## Conclusion

This documentation provides a comprehensive overview of the GeoWake frontend architecture, covering everything from the application entry point to deployment strategies. The frontend leverages Flutter's cross-platform capabilities to deliver a consistent, performant experience across web, mobile, and desktop platforms.

**Key Takeaways:**
- **Flutter Framework**: Modern, reactive UI framework with hot reload
- **Service-Oriented Architecture**: Clear separation of concerns
- **Secure API Integration**: Server-side API key management
- **Offline Support**: Local caching with graceful degradation
- **Battery Optimization**: Adaptive tracking based on power level
- **Real-Time Tracking**: GPS + sensor fusion for accurate positioning
- **Rich Notifications**: Full-screen alarms with sound and vibration

For questions or contributions, please refer to the main [README.md](../README.md).
