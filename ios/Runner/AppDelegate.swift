import Flutter
import UIKit
import UserNotifications
import CoreLocation
import GoogleMaps

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Load Google Maps API key securely from environment at runtime
    // This avoids hardcoding the key in the binary
    loadGoogleMapsAPIKeySecurely()
    
    // Configure notification settings for iOS 10+
    if #available(iOS 10.0, *) {
      UNUserNotificationCenter.current().delegate = self
      let authOptions: UNAuthorizationOptions = [.alert, .badge, .sound]
      UNUserNotificationCenter.current().requestAuthorization(
        options: authOptions,
        completionHandler: { _, _ in }
      )
    }
    
    application.registerForRemoteNotifications()
    
    // Initialize Flutter plugins
    GeneratedPluginRegistrant.register(with: self)
    
    // Important: Allow app to continue running in background for location updates
    // This is required for geolocator to work properly on iOS
    application.applicationIconBadgeNumber = 0
    
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
  
  private func loadGoogleMapsAPIKeySecurely() {
    // Priority 1: Info.plist (works with Xcode builds)
    if let infoPlistApiKey = Bundle.main.infoDictionary?["com.google.ios.API_KEY"] as? String,
       !infoPlistApiKey.isEmpty {
      GMSServices.provideAPIKey(infoPlistApiKey)
      return
    }
    
    // Priority 2: Environment variable (works with flutter run from CLI)
    if let envApiKey = ProcessInfo.processInfo.environment["GOOGLE_MAPS_API_KEY"],
       !envApiKey.isEmpty {
      GMSServices.provideAPIKey(envApiKey)
      return
    }
    
    // If neither is set, Maps will use server-side endpoints
    // This prevents crashes but limits functionality
  }
  
  // Handle foreground notifications on iOS 10+
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    // Allow notification to display while app is in foreground
    if #available(iOS 14.0, *) {
      completionHandler([.banner, .sound, .badge])
    } else {
      completionHandler([.alert, .sound, .badge])
    }
  }
}

