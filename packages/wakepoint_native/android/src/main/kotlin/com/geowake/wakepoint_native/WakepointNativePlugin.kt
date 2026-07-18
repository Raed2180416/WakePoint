package com.geowake.wakepoint_native

import android.app.NotificationManager
import android.content.Context
import android.os.Build
import android.os.PowerManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class WakepointNativePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var appContext: Context

    companion object {
        // Process-static so the lock survives individual FlutterEngine teardown
        // (e.g. UI isolate destroyed on app-swipe) as long as the process lives.
        private const val WAKE_LOCK_TAG = "WakePoint::TrackingWakeLock"
        private var wakeLock: PowerManager.WakeLock? = null
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "geowake/native")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "acquireWakeLock" -> {
                try {
                    acquireWakeLock()
                    result.success(true)
                } catch (t: Throwable) {
                    result.error("WAKELOCK_ACQUIRE_FAILED", t.message, null)
                }
            }
            "releaseWakeLock" -> {
                try {
                    releaseWakeLock()
                    result.success(true)
                } catch (t: Throwable) {
                    result.error("WAKELOCK_RELEASE_FAILED", t.message, null)
                }
            }
            "isWakeLockHeld" -> result.success(wakeLock?.isHeld == true)
            "canUseFullScreenIntent" -> result.success(canUseFullScreenIntent())
            "isNotificationPolicyAccessGranted" ->
                result.success(isNotificationPolicyAccessGranted())
            "isDndActive" -> result.success(isDndActive())
            else -> result.notImplemented()
        }
    }

    @Synchronized
    private fun acquireWakeLock() {
        val pm = appContext.getSystemService(Context.POWER_SERVICE) as PowerManager
        var lock = wakeLock
        if (lock == null) {
            lock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKE_LOCK_TAG)
            lock.setReferenceCounted(false)
            wakeLock = lock
        }
        if (!lock.isHeld) {
            // Safety ceiling: 6h. Tracking releases explicitly on session end;
            // the timeout only guards against a leaked lock draining the battery.
            lock.acquire(6 * 60 * 60 * 1000L)
        }
    }

    @Synchronized
    private fun releaseWakeLock() {
        val lock = wakeLock ?: return
        if (lock.isHeld) lock.release()
    }

    private fun canUseFullScreenIntent(): Boolean {
        // Below API 34 the OS grants full-screen intents to any holder of the perm.
        if (Build.VERSION.SDK_INT < 34) return true
        val nm = appContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        return nm.canUseFullScreenIntent()
    }

    // #17: does the app hold ACCESS_NOTIFICATION_POLICY, so setBypassDnd(true) on
    // the alarm channel actually takes effect? Without it the bypass silently
    // no-ops and Do Not Disturb can mute the wake. (API 23+.)
    private fun isNotificationPolicyAccessGranted(): Boolean {
        val nm = appContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        return nm.isNotificationPolicyAccessGranted
    }

    // #17: is Do Not Disturb currently filtering interruptions? INTERRUPTION_FILTER_ALL
    // means DND is off; anything else (priority/alarms/none) means it is on. (API 23+.)
    private fun isDndActive(): Boolean {
        val nm = appContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val filter = nm.currentInterruptionFilter
        return filter != NotificationManager.INTERRUPTION_FILTER_ALL &&
            filter != NotificationManager.INTERRUPTION_FILTER_UNKNOWN
    }
}
