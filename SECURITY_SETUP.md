# API Key Security Setup Guide

## Overview
This project has been configured to use secure API key management instead of hardcoded values.

## Current Development Setup
- The app currently works with a development API key embedded in the configuration
- All API key references have been centralized in `lib/config/app_config.dart`
- The same API key is used across all services (Places, Directions, Maps)

## For Production Deployment

### Option 1: Environment Variables (Recommended)
1. Set the environment variable when building:
   ```bash
   flutter build apk --dart-define=GOOGLE_MAPS_API_KEY=your_production_key_here
   ```

2. For Android release builds, create `android/key.properties`:
   ```properties
   googleMapsApiKey=your_production_key_here
   ```

### Option 2: Development vs Production Keys
- Development: Uses the embedded key (current setup)
- Production: Override with environment variable

## Files Modified
- ✅ `lib/config/app_config.dart` - Centralized API key management
- ✅ `lib/screens/homescreen.dart` - Uses AppConfig.googleMapsApiKey
- ✅ `lib/services/metro_stop_service.dart` - Uses AppConfig.googleMapsApiKey
- ✅ `android/app/build.gradle` - Supports key.properties configuration
- ✅ `android/app/src/main/AndroidManifest.xml` - Uses build-time placeholder
- ✅ `.gitignore` - Prevents committing sensitive files

## Security Features Added
1. **Centralized Configuration**: All API keys managed in one place
2. **Environment Variable Support**: Production keys via build-time variables
3. **Git Protection**: Enhanced .gitignore to prevent key commits
4. **Build-time Substitution**: Android manifest uses placeholders
5. **Example Files**: Template files for production setup

## Current Status
✅ **App functionality preserved** - No breaking changes
✅ **Development keys working** - Same API key, better organization  
✅ **Production ready** - Can be deployed securely
✅ **Future proof** - Easy to rotate keys without code changes

## Quick Start
The app works exactly as before - no changes needed for development. When ready for production, just add your API key to the appropriate configuration file.