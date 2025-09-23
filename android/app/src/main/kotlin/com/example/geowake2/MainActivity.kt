package com.example.geowake2

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import com.example.geowake2.AlarmMethodChannelHandler

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        createNotificationChannel()
        
        // Register the method channel for alarm interactions
        AlarmMethodChannelHandler.registerWith(flutterEngine, this)
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            // Create tracking channel
            val trackingChannelId = "geowake_tracking_channel"
            val trackingChannelName = "GeoWake Tracking"
            val trackingChannelDesc = "Tracking notification for GeoWake"
            val trackingImportance = NotificationManager.IMPORTANCE_LOW
            val trackingChannel = NotificationChannel(trackingChannelId, trackingChannelName, trackingImportance).apply {
                description = trackingChannelDesc
            }
            
            // Create alarm channel
            val alarmChannelId = "geowake_alarm_channel_v3"
            val alarmChannelName = "GeoWake Alarms (High Priority)"
            val alarmChannelDesc = "Channel for urgent GeoWake wake-up alarms"
            val alarmImportance = NotificationManager.IMPORTANCE_HIGH
            val alarmChannel = NotificationChannel(alarmChannelId, alarmChannelName, alarmImportance).apply {
                description = alarmChannelDesc
                enableVibration(true)
                vibrationPattern = longArrayOf(0, 500, 500, 500, 500, 500)
                // Use Notification.VISIBILITY_PUBLIC instead of NotificationManager.VISIBILITY_PUBLIC
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            }
            
            // Use context from FlutterActivity to create both channels
            val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            notificationManager.createNotificationChannel(trackingChannel)
            notificationManager.createNotificationChannel(alarmChannel)
        }
    }
}