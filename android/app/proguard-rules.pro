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

# wakepoint_native: the wake-lock + full-screen-intent + DND/FSI-capability native
# plugin, invoked reflectively over a MethodChannel. If R8 strips or renames it in
# a release build, the wake path (wake lock, full-screen takeover, canUseFullScreen
# Intent / notification-policy checks) breaks ONLY in release — a class of bug unit
# tests never see. Keep the whole package + its registrant. (GAP: R8. The keep rule
# is code-fixed; a release-mode on-device wake-path smoke test is still required to
# PROVE it — see VALIDATION_REPORT.)
-keep class com.geowake.wakepoint_native.** { *; }
-dontwarn com.geowake.wakepoint_native.**

# Flutter's generated plugin registrant + reflectively-registered plugins (ads/IAP
# MethodChannels) — keep so a release R8 pass can't strip a plugin the wake/monetise
# paths invoke by name.
-keep class io.flutter.plugins.** { *; }
-keep class io.flutter.embedding.engine.plugins.** { *; }
