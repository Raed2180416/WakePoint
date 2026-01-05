# iOS Location & Background Tracking Setup Guide

## Critical Changes Made for iOS

### 1. **Info.plist Configuration** ✅
Added location background modes to allow app to continue receiving location updates when in background:

```xml
<key>UIBackgroundModes</key>
<array>
    <string>location</string>    <!-- Continuous location updates -->
    <string>fetch</string>       <!-- Background fetch capability -->
    <string>processing</string>  <!-- General background processing -->
</array>
```

**Why this matters:** Without `location` in `UIBackgroundModes`, iOS **completely denies** location updates in the background - your app will be killed or suspended.

### 2. **Location Permission Keys** ✅
All three location permission keys are now configured:

```xml
<key>NSLocationWhenInUseUsageDescription</key>
<string>Location is used to navigate and trigger wake-up alarms near your destination.</string>

<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
<string>Location is used in the background during active trips to ensure timely alerts.</string>

<key>NSLocationAlwaysUsageDescription</key>
<string>Location is used in the background during active trips to ensure timely alerts.</string>
```

### 3. **Notification Permission** ✅
**FIXED:** Notification permission is now properly requested on iOS (was being skipped before).

```dart
// lib/services/permission_service.dart
Future<bool> _requestNotificationPermission() async {
    // Now properly requests on iOS too!
    PermissionStatus status = await Permission.notification.status;
    // ... rest of logic
}
```

### 4. **Entitlements File** ✅
Created `ios/Runner/Runner.entitlements` with:
- Push notification capability
- Application groups (for shared data)
- Keychain access groups

### 5. **AppDelegate Configuration** ✅
Enhanced `AppDelegate.swift` to:
- Register for remote notifications
- Configure UNUserNotificationCenter
- Clear badge numbers on startup
- Allow foreground notifications to display

---

## Testing Checklist for iOS Location

When you run the app on a physical iOS device:

1. **First Run Permissions:**
   - ✅ "Allow location while using the app?" → Tap "Allow"
   - ✅ "Enable background tracking?" → Tap "Allow"
   - ✅ "Enable notifications?" → Tap "Allow"

2. **Verify Location is Working:**
   - Open Settings > GeoWake2 > Location
   - Verify it says "Always" (not "While Using" or "Never")
   - If it says "Never", toggle it to "Always"

3. **Background Tracking Test:**
   - Start a trip in GeoWake
   - Lock your phone (press sleep button)
   - Wait 30 seconds
   - Unlock phone - you should see location updates in real-time
   - Close the app and lock phone again - should still track

4. **Notification Test:**
   - When alarm triggers, notification should appear
   - If locked, notification appears on lock screen with sound/vibration
   - If app open, notification displays as banner at top

---

## Troubleshooting

### "Location permission still denied on iOS"
If after granting permissions, location is still not working:

1. **Go to Settings > GeoWake2**
2. Set Location to "Always" (NOT "While Using")
3. Set Notifications to "Allow"
4. Force close the app (swipe up in App Switcher)
5. Relaunch app

### "Background location stops after a few minutes"
This is often due to:
- Missing `UIBackgroundModes` in Info.plist → **Fixed** ✅
- App being killed by iOS for memory → Consider optimizing tracking
- Location permissions not set to "Always" → User must fix in Settings

### "Notifications not firing"
Check:
- Notifications enabled in Settings > GeoWake2 ✅
- `Permission.notification.request()` called ✅ (now fixed)
- Device not in Do Not Disturb mode

---

## Key Differences from Android

| Feature | Android | iOS |
|---------|---------|-----|
| Background Service | ForegroundService | UIBackgroundModes |
| Permission Request | Runtime at app start | At first use + Settings |
| Location Accuracy | High (~10m) | High (~10m) |
| Notification Dismissal | User can dismiss | Limited during active tracking |
| GPS Behavior | Runs continuously | May be throttled by OS |

---

## Files Modified

- ✅ `ios/Runner/Info.plist` - Added UIBackgroundModes
- ✅ `ios/Runner/AppDelegate.swift` - Enhanced notification handling
- ✅ `ios/Runner/Runner.entitlements` - Added capabilities
- ✅ `ios/Podfile` - Set minimum iOS 14.0
- ✅ `lib/services/permission_service.dart` - Fixed iOS notification permission

All the core tracking logic in `lib/services/trackingservice.dart` already had iOS support - no changes needed there!
