# GeoWake

**Never miss your stop.** GeoWake is a location-based wake-up alarm for transit commuters — metro, bus, or car. Set a destination, and GeoWake monitors your journey in real time, alerting you just before you arrive.

Flutter, Android-first, India-first. iOS support is partial (no background location).

---

## Quickstart

### Prerequisites

- Flutter 3.44.x (stable)
- Android SDK 35 (minSdk 24)
- A Google Maps API key with Directions, Places, and Geocoding enabled

### Setup

```bash
flutter pub get
```

Create `android/key.properties`:
```
googleMapsApiKey=YOUR_GOOGLE_MAPS_API_KEY
```

For the backend server (`geowake-server/`), create `.env`:
```
GOOGLE_MAPS_API_KEY=YOUR_KEY
JWT_SECRET=your_32_plus_char_secret
APP_BUNDLE_ID=com.geowake.app
```

### Run

```bash
# App
flutter run

# Backend
cd geowake-server && npm install && npm start
```

### Test

```bash
flutter test                    # full suite (1373+ tests)
flutter analyze lib/            # static analysis (0 errors)
```

---

## What GeoWake Does

1. **Set a destination** — search via Google Places or pick from recents
2. **Choose alarm mode** — distance-based, time-based, or stops-based (metro mode)
3. **Arm the alarm** — GeoWake starts a foreground service tracking your position
4. **Sleep / commute** — the app runs in the background, surviving screen-off and OEM battery killers
5. **Wake up** — GeoWake fires a high-priority full-screen alarm with sound + vibration before you reach your stop

### Pro Features (₹199 one-time)

- **Anti-theft mode** — accelerometer + gyroscope snatch detection triggers a loud alarm if someone moves your phone
- **Guardian mode** — auto-share your commute with a saved contact; "arrived safely" push notification
- **Custom alarm sounds** — personalized wake tones
- **Home-screen widget** — quick arm/disarm from the home screen
- **Ad-free** — remove all banner ads

The **core wake alarm is always free**. Reliability features (foreground service, exact-alarm backstop) are never gated.

---

## Project Structure

```
WakePoint/
├── lib/                          # Flutter app
│   ├── main.dart                 # Entry point, routing, service init
│   ├── config/                   # App config, test flags, power policy
│   ├── core/                     # EKF, clock, logging, reachability
│   ├── dashboard/                # Simulation dashboards & dev tools
│   ├── l10n/                     # Localization (80+ languages)
│   ├── models/                   # Route models
│   ├── screens/                  # UI screens
│   ├── services/                 # All business logic
│   │   ├── tracking/             # Modular tracking components
│   │   ├── monetization/         # IAP, premium, ads
│   │   ├── data_asset/           # Consent-gated DP aggregate pipeline
│   │   ├── share/                # Journey sharing & guardian
│   │   ├── telemetry/            # Error & event logging
│   │   ├── reliability/          # Preflight checks
│   │   ├── widget/               # Home screen widget bridge
│   │   └── ...                   # Tracking, notifications, EKF, etc.
│   ├── themes/                   # Light/dark themes
│   └── widgets/                  # Reusable UI components
├── geowake-server/               # Express.js backend
│   └── src/
│       ├── config/               # Env config
│       ├── controllers/          # Auth, maps proxy, aggregate
│       ├── middleware/           # JWT auth, rate limiting
│       ├── routes/               # Auth, maps, aggregate
│       └── utils/                # Cache, merge engine
├── android/                      # Android native config
├── test/                         # 1373+ tests
├── packages/wakepoint_native/    # Native Android plugin (full-screen intent)
└── docs/                         # Architecture docs
```

## Branches

- **`production-ready-audit-v2`** — active development
- **`stable-release-1`** — release branch

## Documentation

- [Architecture](docs/ARCHITECTURE.md) — complete system design
- [Backend API](docs/BACKEND.md) — server endpoints and contracts
- [Android Setup](docs/ANDROID.md) — permissions, build config, native plugin
- [Testing](docs/TESTING.md) — test suite structure and CI gates
- [Privacy & Data](docs/PRIVACY.md) — consent, DP, k-anonymity, data asset pipeline
