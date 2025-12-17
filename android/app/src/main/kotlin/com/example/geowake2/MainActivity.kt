package com.example.geowake2

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.media.AudioAttributes
import android.os.Build
import android.os.VibrationAttributes
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val alarmHapticsChannelName = "geowake/alarm_haptics"

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        createNotificationChannel()

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, alarmHapticsChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        try {
                            val patternArg = call.argument<List<Int>>("pattern")
                            val pattern = (patternArg ?: listOf(0, 500, 250, 500, 250, 1000, 500))
                                .map { it.toLong() }
                                .toLongArray()
                            startAlarmVibration(pattern)
                            result.success(null)
                        } catch (t: Throwable) {
                            result.error("ALARM_HAPTICS_START_FAILED", t.message, null)
                        }
                    }
                    "stop" -> {
                        try {
                            stopAlarmVibration()
                            result.success(null)
                        } catch (t: Throwable) {
                            result.error("ALARM_HAPTICS_STOP_FAILED", t.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun getVibrator(): Vibrator {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val vm = getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager
            vm.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        }
    }

    private fun startAlarmVibration(pattern: LongArray) {
        val vibrator = getVibrator()
        if (!vibrator.hasVibrator()) return

        // Ensure a repeated "start" actually restarts the motor.
        @Suppress("DEPRECATION")
        vibrator.cancel()

        val repeatIndex = 0

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val effect = VibrationEffect.createWaveform(pattern, repeatIndex)
            val attrs = VibrationAttributes.Builder()
                .setUsage(VibrationAttributes.USAGE_ALARM)
                .build()
            vibrator.vibrate(effect, attrs)
            return
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val effect = VibrationEffect.createWaveform(pattern, repeatIndex)
            val audioAttrs = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_ALARM)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()
            vibrator.vibrate(effect, audioAttrs)
            return
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            val audioAttrs = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_ALARM)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()
            @Suppress("DEPRECATION")
            vibrator.vibrate(pattern, repeatIndex, audioAttrs)
            return
        }

        @Suppress("DEPRECATION")
        vibrator.vibrate(pattern, repeatIndex)
    }

    private fun stopAlarmVibration() {
        val vibrator = getVibrator()
        @Suppress("DEPRECATION")
        vibrator.cancel()
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
                // Disable channel vibration to avoid double-vibration with the
                // app-controlled alarm vibration loop.
                enableVibration(false)
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