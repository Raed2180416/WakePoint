package com.example.geowake2

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider

/**
 * GeoWake home-screen widget provider (FEATURES_SPEC §3.6-A).
 *
 * DISPLAY / OBSERVER ONLY. It renders the small key/value snapshot that
 * [HomeWidgetBridge] (Dart) mirrors into the widget SharedPreferences and wires
 * a single LAUNCH pending intent — carrying the gw_widget_deeplink URI — onto
 * the whole card. Tapping it just brings MainActivity to the foreground, where
 * the Dart side (WidgetArmHandler / HomeScreen) runs the normal one-tap arm
 * through the unchanged permission + reliability preflight + startTracking flow.
 *
 * It NEVER starts tracking, computes ETA, or touches the arm→track→alarm spine.
 * If any field is missing it degrades to a neutral "Open GeoWake" card — a
 * broken/absent bridge can never present a misleading or half-armed state.
 *
 * The key names below are the contract with HomeWidgetBridge.f* (Dart); the
 * `widget_field_contract_test.dart` asserts they stay in sync.
 */
class GeoWakeWidgetProvider : HomeWidgetProvider() {

    companion object {
        private const val F_STATE = "gw_widget_state"
        private const val F_TITLE = "gw_widget_title"
        private const val F_SUBTITLE = "gw_widget_subtitle"
        private const val F_PROGRESS = "gw_widget_progress"
        private const val F_CTA = "gw_widget_cta"
        private const val F_DEEPLINK = "gw_widget_deeplink"

        // Mirrors WidgetRenderState.name (Dart).
        private const val STATE_ACTIVE = "active"
    }

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences
    ) {
        val title = widgetData.getString(F_TITLE, null) ?: "GeoWake"
        val subtitle = widgetData.getString(F_SUBTITLE, null)
            ?: "Open GeoWake to set up your next commute."
        val cta = widgetData.getString(F_CTA, null) ?: "Open"
        val state = widgetData.getString(F_STATE, null) ?: ""
        val progress = widgetData.getString(F_PROGRESS, null)?.toIntOrNull() ?: 0
        val deepLink = widgetData.getString(F_DEEPLINK, null)

        appWidgetIds.forEach { widgetId ->
            val views = RemoteViews(context.packageName, R.layout.geowake_widget).apply {
                setTextViewText(R.id.gw_widget_title, title)
                setTextViewText(R.id.gw_widget_subtitle, subtitle)
                setTextViewText(R.id.gw_widget_cta, cta)

                // Progress bar is meaningful only while a journey is live.
                if (state == STATE_ACTIVE) {
                    setProgressBar(R.id.gw_widget_progress, 100, progress.coerceIn(0, 100), false)
                    setViewVisibility(R.id.gw_widget_progress, View.VISIBLE)
                } else {
                    setViewVisibility(R.id.gw_widget_progress, View.GONE)
                }

                // One LAUNCH intent (carrying the deep-link URI) on the card AND the
                // CTA. HomeWidgetLaunchIntent uses an explicit MainActivity intent,
                // so it needs no manifest intent-filter; the home_widget plugin
                // delivers the URI to Dart's widgetClicked / initiallyLaunched stream.
                val uri: Uri? = deepLink?.let { runCatching { Uri.parse(it) }.getOrNull() }
                val pendingIntent = HomeWidgetLaunchIntent.getActivity(
                    context,
                    MainActivity::class.java,
                    uri
                )
                setOnClickPendingIntent(R.id.gw_widget_container, pendingIntent)
                setOnClickPendingIntent(R.id.gw_widget_cta, pendingIntent)
            }

            appWidgetManager.updateAppWidget(widgetId, views)
        }
    }
}
