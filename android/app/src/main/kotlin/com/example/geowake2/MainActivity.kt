package com.example.geowake2

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.media.AudioManager
import android.os.Build
import android.os.VibrationAttributes
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import androidx.annotation.NonNull
import androidx.annotation.RequiresApi
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val alarmHapticsChannelName = "geowake/alarm_haptics"

    // G8: bridge that lets native tell Dart a routed headset just disconnected
    // (Android AudioManager.ACTION_AUDIO_BECOMING_NOISY) so the alarm audio can
    // be forced back onto the loudspeaker.
    private val audioRouteChannelName = "geowake/alarm_audio"
    private var audioRouteChannel: MethodChannel? = null
    private var noisyReceiverRegistered = false

    // G25: escalating alarm waveform (soft -> strong) that then loops its strong
    // tail, so deep / hard-of-hearing riders on a soft seat are progressively and
    // then persistently buzzed. Amplitudes ramp 110 -> 255 where the motor
    // supports amplitude control; otherwise the timings alone still loop strongly.
    private val alarmTimings =
        longArrayOf(0, 400, 200, 700, 200, 1000, 250, 1400, 300, 1400, 300)
    private val alarmAmplitudes =
        intArrayOf(0, 110, 0, 160, 0, 205, 0, 255, 0, 255, 0)
    private val alarmRepeatIndex = 5 // loop from the first 1000ms strong pulse onward

    private val becomingNoisyReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) {
                // Runs on the main thread (registered without a Handler), so it is
                // safe to invoke the Flutter method channel directly.
                audioRouteChannel?.invokeMethod("audioBecomingNoisy", null)
            }
        }
    }

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        createNotificationChannel()

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, alarmHapticsChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        try {
                            // G25: escalation shape is owned natively; the Dart-side
                            // pattern (if any) is ignored here in favour of the strong
                            // alarm-usage waveform.
                            startAlarmVibration()
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

        // G8: register the audio-route bridge + system receiver.
        audioRouteChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            audioRouteChannelName
        )
        try {
            registerReceiver(
                becomingNoisyReceiver,
                IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
            )
            noisyReceiverRegistered = true
        } catch (t: Throwable) {
            noisyReceiverRegistered = false
        }
    }

    override fun onDestroy() {
        if (noisyReceiverRegistered) {
            try {
                unregisterReceiver(becomingNoisyReceiver)
            } catch (t: Throwable) {
                // Already unregistered; ignore.
            }
            noisyReceiverRegistered = false
        }
        super.onDestroy()
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

    private fun startAlarmVibration() {
        val vibrator = getVibrator()
        if (!vibrator.hasVibrator()) return

        // Ensure a repeated "start" actually restarts the motor.
        @Suppress("DEPRECATION")
        vibrator.cancel()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val effect = buildAlarmEffect(vibrator)
            val attrs = VibrationAttributes.Builder()
                .setUsage(VibrationAttributes.USAGE_ALARM)
                .build()
            vibrator.vibrate(effect, attrs)
            return
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val effect = buildAlarmEffect(vibrator)
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
            vibrator.vibrate(alarmTimings, alarmRepeatIndex, audioAttrs)
            return
        }

        @Suppress("DEPRECATION")
        vibrator.vibrate(alarmTimings, alarmRepeatIndex)
    }

    @RequiresApi(Build.VERSION_CODES.O)
    private fun buildAlarmEffect(vibrator: Vibrator): VibrationEffect {
        // Prefer amplitude escalation where the motor supports it; otherwise fall
        // back to the timing-only waveform (still loops the strong tail).
        return if (vibrator.hasAmplitudeControl()) {
            VibrationEffect.createWaveform(alarmTimings, alarmAmplitudes, alarmRepeatIndex)
        } else {
            VibrationEffect.createWaveform(alarmTimings, alarmRepeatIndex)
        }
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

            // G9: create/settle the alarm channel natively so the DND-bypass and
            // alarm-usage settings are locked in BEFORE the Dart side ever posts.
            // Channel property changes are ignored by Android once a channel
            // exists, so creating v4 here (before Dart's initialize()) makes these
            // settings authoritative. Aligned to v4 (Dart posts on v4); the stale
            // v3 channel is no longer created.
            val alarmChannelId = "geowake_alarm_channel_v4"
            val alarmChannelName = "GeoWake Alarms (High Priority)"
            val alarmChannelDesc = "Channel for urgent GeoWake wake-up alarms"
            val alarmImportance = NotificationManager.IMPORTANCE_HIGH
            val alarmAudioAttrs = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_ALARM)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()
            val alarmChannel = NotificationChannel(alarmChannelId, alarmChannelName, alarmImportance).apply {
                description = alarmChannelDesc
                // Disable channel vibration/sound: the app drives both the alarm
                // audio (AlarmPlayer) and the escalating vibration loop itself.
                // A null sound with alarm audio attributes keeps the channel silent
                // while still classifying it as an alarm-usage channel.
                enableVibration(false)
                setSound(null, alarmAudioAttrs)
                // Use Notification.VISIBILITY_PUBLIC instead of NotificationManager.VISIBILITY_PUBLIC
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                // G9a: bypass Do-Not-Disturb where allowed. This only takes effect
                // once the user grants notification-policy access (see the
                // ACCESS_NOTIFICATION_POLICY permission in the manifest); calling it
                // without that access is a harmless no-op. Guarded defensively.
                try {
                    setBypassDnd(true)
                } catch (t: Throwable) {
                    // Policy access not granted / not supported: ignore.
                }
            }

            // Backstop channel: MUST sound on its own even if the app process was
            // killed. The setAlarmClock ETA backstop posts here. Unlike the live
            // alarm channel — which is intentionally silent because AlarmPlayer drives
            // audio from the running isolate — this channel carries the system default
            // ALARM tone + vibration, so a DEAD process can still wake the rider.
            val backstopChannel = NotificationChannel(
                "geowake_backstop_channel_v1",
                "GeoWake Backstop Alarm",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Last-resort wake alarm that sounds even if the app was killed"
                setSound(
                    RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM),
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ALARM)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                )
                enableVibration(true)
                vibrationPattern = longArrayOf(0, 600, 300, 600, 300, 600)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                try {
                    setBypassDnd(true)
                } catch (t: Throwable) {
                    // Policy access not granted / not supported: ignore.
                }
            }

            // Use context from FlutterActivity to create the channels
            val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            notificationManager.createNotificationChannel(trackingChannel)
            notificationManager.createNotificationChannel(alarmChannel)
            notificationManager.createNotificationChannel(backstopChannel)
        }
    }
}
