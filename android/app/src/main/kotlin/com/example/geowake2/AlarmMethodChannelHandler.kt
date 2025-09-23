package com.example.geowake2

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

class AlarmMethodChannelHandler(private val activity: Activity) : MethodCallHandler {
    companion object {
        private const val CHANNEL = "com.example.geowake2/alarm"

        @JvmStatic
        fun registerWith(engine: FlutterEngine, activity: Activity) {
            val channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            channel.setMethodCallHandler(AlarmMethodChannelHandler(activity))
        }
    }

    private val context: Context = activity.applicationContext

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "launchAlarmActivity" -> {
                try {
                    startVibration()

                    val title = call.argument<String>("title")
                    val body = call.argument<String>("body")
                    val allowContinue = call.argument<Boolean>("allowContinue") ?: true

                    val intent = Intent(context, AlarmActivity::class.java)
                    intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)

                    val extras = Bundle()
                    extras.putString("title", title ?: "Wake Up!")
                    extras.putString("body", body ?: "Approaching destination")
                    extras.putBoolean("allowContinue", allowContinue)
                    intent.putExtras(extras)

                    context.startActivity(intent)
                    result.success(true)
                } catch (e: Exception) {
                    result.error("LAUNCH_FAILED", "Failed to launch AlarmActivity", e.message)
                }
            }
            "stopVibration" -> {
                stopVibration()
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    private fun startVibration() {
        try {
            val vibratePattern = longArrayOf(0, 500, 250, 500, 250, 500, 250, 1000, 500)

            val vibrator: Vibrator? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val vm = context.getSystemService(VibratorManager::class.java)
                vm?.defaultVibrator
            } else {
                @Suppress("DEPRECATION")
                context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
            }

            if (vibrator != null) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    val effect = VibrationEffect.createWaveform(vibratePattern, 0)
                    vibrator.vibrate(effect)
                } else {
                    @Suppress("DEPRECATION")
                    vibrator.vibrate(vibratePattern, 0)
                }
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    private fun stopVibration() {
        try {
            val vibrator: Vibrator? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val vm = context.getSystemService(VibratorManager::class.java)
                vm?.defaultVibrator
            } else {
                @Suppress("DEPRECATION")
                context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
            }

            vibrator?.cancel()
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }
}
