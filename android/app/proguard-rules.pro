# R8/ProGuard rules. Every directive MUST start with '-' — the previous file was
# missing the leading dashes, which made R8 fail ("Expected char '-' at 1:1") and
# blocked ALL release builds.

# Google Play Services location internals (geolocator) — suppress R8 warnings and
# keep the referenced class.
-dontwarn com.google.android.gms.internal.location.zze
-keep class com.google.android.gms.internal.location.zze { *; }

# flutter_local_notifications: the process-death exact-alarm backstop relies on
# these classes (the manifest-declared ScheduledNotification*/ActionBroadcast
# receivers and the plugin's reflection). Keep them so R8 can't strip the wake
# path in a release build.
-keep class com.dexterous.** { *; }
-dontwarn com.dexterous.**
