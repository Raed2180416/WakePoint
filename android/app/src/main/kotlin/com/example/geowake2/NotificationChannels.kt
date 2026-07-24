package com.example.geowake2

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build

/**
 * Single source of truth for GeoWake's notification channels.
 *
 * WHY THIS EXISTS: the alarm + backstop channels carry alarm-usage audio, DND
 * bypass, and (for the backstop) the system ALARM tone — settings Android locks
 * in at channel-creation time and ignores forever after. Previously these were
 * created only in MainActivity (i.e. when the UI Activity launched). But the
 * OS-scheduled exact-alarm backstop can fire after a device REBOOT mid-journey,
 * from the background service / AlarmManager receiver, with the UI never having
 * launched since boot — so the backstop channel might not exist yet, and a
 * notification posted to a missing channel loses its alarm sound + bypass.
 *
 * Creating the channels here and invoking [ensure] from Application.onCreate
 * (which runs for EVERY process start — UI, background service, AlarmManager
 * receiver) guarantees the channels exist, with the correct authoritative
 * settings, before anything posts to them. Channel creation is idempotent, so
 * MainActivity can (and does) still call this harmlessly.
 *
 * NOTE: this does NOT solve direct-boot (credential-locked) storage — the
 * scheduled-notification payload lives in credential-encrypted storage and is
 * unreadable before the first unlock after reboot. That is a separate,
 * device-verify concern tracked in docs/business_os/01_launch_readiness.md.
 */
object NotificationChannels {
    fun ensure(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            ?: return

        // Foreground-service / tracking channel (low importance, silent).
        val trackingChannel = NotificationChannel(
            "geowake_tracking_channel",
            "GeoWake Tracking",
            NotificationManager.IMPORTANCE_LOW
        ).apply { description = "Tracking notification for GeoWake" }

        // Live alarm channel: intentionally SILENT — AlarmPlayer drives the audio
        // and the escalating vibration from the running isolate. Alarm-usage
        // attributes + DND bypass are locked in here.
        val alarmAudioAttrs = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_ALARM)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()
        val alarmChannel = NotificationChannel(
            "geowake_alarm_channel_v4",
            "GeoWake Alarms (High Priority)",
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "Channel for urgent GeoWake wake-up alarms"
            enableVibration(false)
            setSound(null, alarmAudioAttrs)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            try { setBypassDnd(true) } catch (t: Throwable) { /* no policy access: no-op */ }
        }

        // Backstop channel: MUST sound on its own even if the app process was
        // killed (setAlarmClock ETA backstop posts here). Carries the system
        // default ALARM tone + vibration so a DEAD or freshly-rebooted process
        // can still wake the rider.
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
            try { setBypassDnd(true) } catch (t: Throwable) { /* no policy access: no-op */ }
        }

        // Course-alert channel: the "you may be heading the WRONG way / boarded the
        // opposite train" heads-up. This must actually reach a dozing rider, so it
        // vibrates, makes a sound, and bypasses DND — but at NOTIFICATION usage (not
        // full ALARM volume) and single-shot (no insistent loop), because
        // wrong-direction detection can false-positive and must not blast the rider
        // awake on a brief GPS glitch. Whether this should escalate to a full wake
        // alarm is a tunable product decision (see 01_launch_readiness.md).
        val courseAlertChannel = NotificationChannel(
            "geowake_course_alert_channel_v1",
            "GeoWake Direction Alerts",
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "Heads-up when you may be heading away from your stop"
            enableVibration(true)
            vibrationPattern = longArrayOf(0, 400, 200, 400)
            setSound(
                RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION),
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
            )
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            try { setBypassDnd(true) } catch (t: Throwable) { /* no policy access: no-op */ }
        }

        nm.createNotificationChannel(trackingChannel)
        nm.createNotificationChannel(alarmChannel)
        nm.createNotificationChannel(backstopChannel)
        nm.createNotificationChannel(courseAlertChannel)
    }
}
