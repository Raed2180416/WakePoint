package com.example.geowake2

import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity

class AlarmActivity : FlutterActivity() {
    private var vibrator: Vibrator? = null
    private val vibratePattern = longArrayOf(0, 500, 500, 500, 500)
    
    override fun onCreate(savedInstanceState: Bundle?) {
        // Set the window flags BEFORE super.onCreate()
        // This ensures the activity appears over the lock screen
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD or
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
            )
        }
        
        // For API >= 27, we need to disable the keyguard explicitly
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            val keyguardManager = getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
            keyguardManager.requestDismissKeyguard(this, null)
        }
        
        // Set audio to use alarm channel
        volumeControlStream = AudioManager.STREAM_ALARM
        
        // Raise volume temporarily for alarm
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val previousVolume = audioManager.getStreamVolume(AudioManager.STREAM_ALARM)
        val maxVolume = audioManager.getStreamMaxVolume(AudioManager.STREAM_ALARM)
        audioManager.setStreamVolume(AudioManager.STREAM_ALARM, (maxVolume * 0.7).toInt(), 0)
        
        super.onCreate(savedInstanceState)
        
        // Start vibration - get vibrator service based on API level
        vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val vibratorManager = getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager
            vibratorManager.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        }
        
        startVibrating()
        
        // Pass along the alarm information to the Flutter layer
        if (intent?.extras != null) {
            val extras = intent.extras
            if (extras != null) {
                val flutterIntent = Intent("com.example.geowake2.ALARM_TRIGGERED")
                flutterIntent.putExtras(extras)
                sendBroadcast(flutterIntent)
            }
        }
    }
    
    private fun startVibrating() {
        vibrator?.let {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val audioAttributes = AudioAttributes.Builder()
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .setUsage(AudioAttributes.USAGE_ALARM)
                    .build()
                
                it.vibrate(
                    VibrationEffect.createWaveform(vibratePattern, 0), // Repeat indefinitely
                    audioAttributes
                )
            } else {
                @Suppress("DEPRECATION")
                it.vibrate(vibratePattern, 0) // Repeat indefinitely
            }
        }
    }
    
    override fun onDestroy() {
        // Stop vibration when activity is destroyed
        vibrator?.cancel()
        super.onDestroy()
    }
}