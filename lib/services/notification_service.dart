// lib/services/notification_service.dart

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

class NotificationService {
  // Singleton pattern to ensure only one instance of this service
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  // Allows tests to disable platform/plugin calls.
  static bool isTestMode = false;

  final FlutterLocalNotificationsPlugin _notificationsPlugin = FlutterLocalNotificationsPlugin();

  // Initialize the notification service
  Future<void> initialize() async {
    // Settings for Android initialization
    const AndroidInitializationSettings androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    
    // Settings for iOS initialization
    const DarwinInitializationSettings iosSettings = DarwinInitializationSettings();

    const InitializationSettings settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _notificationsPlugin.initialize(settings);
  }

  // This is the main function to trigger the alarm
  Future<void> showWakeUpAlarm({
    required String title,
    required String body,
  }) async {
    if (isTestMode) {
      return;
    }
    // 1. Read the saved ringtone from SharedPreferences
    final prefs = await SharedPreferences.getInstance();
    // Default to the first ringtone if none is saved
    final String ringtonePath = prefs.getString('selected_ringtone') ?? 'assets/ringtones/(One UI) Asteroid.ogg';
    
    // The sound file name must be WITHOUT the extension for this package
    final String soundName = ringtonePath.split('/').last.split('.').first;

    // 2. Define the Android notification details, including the custom sound
    final AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'geowake_alarm_channel', // A unique ID for the channel
      'GeoWake Alarms',        // A user-visible name for the channel
      channelDescription: 'Channel for GeoWake wake-up alarms',
      importance: Importance.max,
      priority: Priority.high,
      sound: RawResourceAndroidNotificationSound(soundName), // This links to your .ogg file
      playSound: true,
      // You can also add vibration, full-screen intent, etc. here
    );

    // Define iOS notification details (sound name should be included in the app bundle)
    final DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
      presentSound: true,
      sound: '$soundName.ogg', // For iOS, you may need the extension
    );

    final NotificationDetails notificationDetails = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    // 3. Show the notification
    await _notificationsPlugin.show(
      0, // Notification ID
      title,
      body,
      notificationDetails,
    );
  }
}