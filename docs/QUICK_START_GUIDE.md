# GeoWake Quick Start Guide

This guide will help you get the GeoWake project up and running for development and testing.

---

## Prerequisites

### Required Software

- **Node.js** 18.x or higher ([Download](https://nodejs.org/))
- **Flutter** 3.7.0 or higher ([Install Guide](https://flutter.dev/docs/get-started/install))
- **Git** ([Download](https://git-scm.com/downloads))
- **Android Studio** (for Android development) or **Xcode** (for iOS development)

### Required API Keys

- **Google Maps API Key** - Get from [Google Cloud Console](https://console.cloud.google.com/)
  - Enable these APIs:
    - Maps SDK for Android
    - Maps SDK for iOS
    - Directions API
    - Places API
    - Geocoding API

---

## Repository Setup

### 1. Clone the Repository

```bash
git clone https://github.com/Raed2180416/GeoWake.git
cd GeoWake
```

### 2. Project Structure

```
GeoWake/
├── geowake-server/          # Backend Node.js server
│   ├── src/                 # Server source code
│   ├── test/                # Backend tests
│   └── package.json         # Node dependencies
│
├── lib/                     # Flutter app source code
│   ├── services/            # API client, tracking services
│   ├── screens/             # UI screens
│   └── main.dart            # App entry point
│
├── test/                    # Flutter unit tests
├── integration_test/        # Flutter integration tests
├── docs/                    # Documentation
└── pubspec.yaml             # Flutter dependencies
```

---

## Backend Setup

### 1. Navigate to Server Directory

```bash
cd geowake-server
```

### 2. Install Dependencies

```bash
npm install
```

This installs:
- Express.js and middleware
- JWT authentication
- Google Maps API client (axios)
- Testing framework (Jest + Supertest)

### 3. Create Environment File

Create `.env` file in `geowake-server/` directory:

```bash
# .env
GOOGLE_MAPS_API_KEY=your_google_maps_api_key_here
JWT_SECRET=your_jwt_secret_at_least_32_characters_long_minimum
NODE_ENV=development
APP_BUNDLE_ID=com.yourcompany.geowake2
PORT=3000
MAX_REQUESTS_PER_HOUR=1000
MAX_REQUESTS_PER_MINUTE=100
ALLOWED_ORIGINS=*
```

**Important:**
- Replace `your_google_maps_api_key_here` with actual API key
- Replace `your_jwt_secret...` with a secure random string (min 32 chars)
- Never commit this file to Git (already in `.gitignore`)

### 4. Start Development Server

```bash
npm run dev
```

You should see:
```
🌍 ================================
🚀 GeoWake API Server Started!
🌍 ================================
📍 Environment: development
🌐 Port: 3000
🔑 Google Maps API: ✅ Configured
🛡️  JWT Secret: ✅ Configured
📱 Bundle ID: com.yourcompany.geowake2
⏰ Started at: 2024-01-15T10:30:00.000Z
🌍 ================================
```

### 5. Test Backend Endpoints

**Health Check:**
```bash
curl http://localhost:3000/api/health
```

**Get Authentication Token:**
```bash
curl -X POST http://localhost:3000/api/auth/token \
  -H "Content-Type: application/json" \
  -d '{"bundleId":"com.yourcompany.geowake2"}'
```

**Test Directions API:**
```bash
# First, get a token from the previous command, then:
curl -X POST http://localhost:3000/api/maps/directions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_TOKEN_HERE" \
  -d '{
    "origin": "40.7128,-74.0060",
    "destination": "40.7580,-73.9855",
    "mode": "transit"
  }'
```

### 6. Run Backend Tests

```bash
npm test
```

Expected output:
```
 PASS  test/auth.test.js
 PASS  test/maps.test.js

Test Suites: 2 passed, 2 total
Tests:       38 passed, 38 total
```

---

## Frontend Setup

### 1. Navigate to Project Root

```bash
cd ..  # From geowake-server/ back to GeoWake/
```

### 2. Install Flutter Dependencies

```bash
flutter pub get
```

### 3. Configure API Base URL

For local development, update the API client to point to local server:

**Edit `lib/services/api_client.dart`:**
```dart
// Change this line:
static const String _baseUrl = 'https://geowake-production.up.railway.app/api';

// To:
static const String _baseUrl = 'http://localhost:3000/api';
// Or for Android emulator:
// static const String _baseUrl = 'http://10.0.2.2:3000/api';
```

**Note:** Remember to change it back to production URL before building release.

### 4. Check Flutter Installation

```bash
flutter doctor
```

Fix any issues reported (missing SDK, licenses, etc.)

### 5. Run Flutter Tests

```bash
flutter test
```

Expected output:
```
00:02 +38: All tests passed!
```

### 6. Run the App

**For Android:**
```bash
flutter run
```

**For iOS:**
```bash
flutter run
```

**For Web (testing only):**
```bash
flutter run -d chrome
```

---

## Development Workflow

### Day-to-Day Development

#### Terminal 1: Backend Server (with auto-reload)
```bash
cd geowake-server
npm run dev
```
Watches for changes and auto-restarts server.

#### Terminal 2: Flutter App (with hot reload)
```bash
cd GeoWake
flutter run
```
Press `r` to hot reload, `R` to hot restart.

### Before Committing Changes

1. **Run Backend Tests:**
   ```bash
   cd geowake-server
   npm test
   ```

2. **Run Flutter Tests:**
   ```bash
   cd ..
   flutter test
   ```

3. **Check Flutter Code:**
   ```bash
   flutter analyze
   ```

4. **Commit:**
   ```bash
   git add .
   git commit -m "Your commit message"
   git push
   ```

---

## Testing

### Backend Tests

**Run all tests:**
```bash
cd geowake-server
npm test
```

**Run specific test file:**
```bash
npm test auth.test.js
npm test maps.test.js
```

**Run with coverage:**
```bash
npm run test:coverage
```

**Watch mode (auto-rerun on changes):**
```bash
npm run test:watch
```

### Frontend Tests

**Run all tests:**
```bash
flutter test
```

**Run specific test:**
```bash
flutter test test/places_session_token_test.dart
```

**Run with coverage:**
```bash
flutter test --coverage
```

**Run integration tests:**
```bash
flutter test integration_test/
```

---

## Common Issues & Solutions

### Backend Issues

**Problem:** `JWT_SECRET must be at least 32 characters long`  
**Solution:** Update `.env` file with longer JWT_SECRET (min 32 chars)

**Problem:** `GOOGLE_MAPS_API_KEY is required`  
**Solution:** Add valid API key to `.env` file

**Problem:** `Port 3000 already in use`  
**Solution:** 
```bash
# Find process using port 3000
lsof -i :3000  # macOS/Linux
netstat -ano | findstr :3000  # Windows

# Kill the process or change PORT in .env
```

**Problem:** Tests fail with timeout  
**Solution:** Check that .env file exists and has valid credentials

### Frontend Issues

**Problem:** `ApiClient` fails to connect  
**Solution:** 
- Ensure backend server is running
- Check API base URL in `api_client.dart`
- For Android emulator, use `http://10.0.2.2:3000/api`
- For iOS simulator, use `http://localhost:3000/api`

**Problem:** Google Maps not displaying  
**Solution:** 
- Check API key configuration
- Ensure Maps SDK is enabled in Google Cloud Console
- Check Android manifest / iOS Info.plist for API key

**Problem:** `flutter pub get` fails  
**Solution:**
```bash
flutter clean
flutter pub get
```

**Problem:** Build fails on Android  
**Solution:**
```bash
cd android
./gradlew clean
cd ..
flutter clean
flutter pub get
flutter run
```

---

## Building for Production

### Backend (Railway Deployment)

The backend auto-deploys when you push to GitHub main branch. No manual steps needed.

To deploy manually:
1. Push changes to GitHub
2. Railway detects changes
3. Builds and deploys automatically

### Frontend

#### Android APK

```bash
flutter build apk --release
```

Output: `build/app/outputs/flutter-apk/app-release.apk`

#### iOS App

```bash
flutter build ios --release
```

Then use Xcode to archive and upload to App Store.

#### App Bundle (for Google Play)

```bash
flutter build appbundle --release
```

Output: `build/app/outputs/bundle/release/app-release.aab`

---

## Project URLs

- **Production API:** https://geowake-production.up.railway.app
- **GitHub Repository:** https://github.com/Raed2180416/GeoWake
- **Railway Dashboard:** https://railway.app (login required)

---

## Documentation

- **Main README:** `README.md`
- **API Documentation:** `docs/FRONTEND_BACKEND_CONNECTIVITY.md`
- **Railway Guide:** `docs/RAILWAY_DEPLOYMENT.md`
- **Testing Overview:** `docs/API_TESTING_OVERVIEW.md`
- **Backend Tests:** `geowake-server/test/README.md`
- **Security Setup:** `SECURITY_SETUP.md`

---

## Getting Help

### Resources

- **Flutter Documentation:** https://flutter.dev/docs
- **Express.js Guide:** https://expressjs.com/
- **Railway Docs:** https://docs.railway.app/
- **Google Maps APIs:** https://developers.google.com/maps

### Debugging Tips

1. **Check Logs:**
   - Backend: Terminal output from `npm run dev`
   - Flutter: Terminal output from `flutter run`
   - Railway: Dashboard → Logs tab

2. **Use Debug Mode:**
   - Backend: Add `console.log()` statements
   - Flutter: Use `dev.log()` from `dart:developer`

3. **Test Endpoints:**
   - Use `curl` commands (shown above)
   - Use Postman or Insomnia
   - Use browser DevTools

4. **Verify Environment:**
   ```bash
   # Backend
   cat geowake-server/.env  # Should show your variables
   
   # Flutter
   flutter doctor  # Should show all checkmarks
   ```

---

## Next Steps

After getting everything running:

1. ✅ **Explore the code** - Read through key files
2. ✅ **Run tests** - Make sure everything passes
3. ✅ **Make a small change** - Edit a file, test it
4. ✅ **Read documentation** - Understand the architecture
5. ✅ **Try the app** - Install on device, use it
6. ✅ **Check Railway** - See your backend in action

---

**Last Updated:** 2024-01-15  
**Maintained By:** GeoWake Development Team
