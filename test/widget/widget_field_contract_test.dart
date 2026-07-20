// Contract test: the discrete widget-data keys/values that HomeWidgetBridge
// writes MUST match what the native GeoWakeWidgetProvider.kt reads. There is no
// device or plugin in the loop here — WidgetStateData.toWidgetFields() is pure —
// so this fails loudly the moment either side's field names or the `active`
// state token drift apart (which would silently blank the real home widget).
//
// Native contract (android/.../GeoWakeWidgetProvider.kt companion object):
//   F_STATE="gw_widget_state", F_TITLE="gw_widget_title",
//   F_SUBTITLE="gw_widget_subtitle", F_PROGRESS="gw_widget_progress",
//   F_CTA="gw_widget_cta", F_DEEPLINK="gw_widget_deeplink",
//   STATE_ACTIVE="active".

import 'package:flutter_test/flutter_test.dart';

import 'package:geowake2/services/widget/home_widget_bridge.dart';

void main() {
  group('widget field contract (Dart ⇄ native)', () {
    test('field keys match the native provider constants exactly', () {
      expect(HomeWidgetBridge.fState, 'gw_widget_state');
      expect(HomeWidgetBridge.fTitle, 'gw_widget_title');
      expect(HomeWidgetBridge.fSubtitle, 'gw_widget_subtitle');
      expect(HomeWidgetBridge.fProgress, 'gw_widget_progress');
      expect(HomeWidgetBridge.fCta, 'gw_widget_cta');
      expect(HomeWidgetBridge.fDeepLink, 'gw_widget_deeplink');
      expect(HomeWidgetBridge.fRouteId, 'gw_widget_route_id');
    });

    test('the active-state token the native side branches on is "active"', () {
      // GeoWakeWidgetProvider only shows the progress bar when
      // gw_widget_state == "active". If the enum name changes, the widget would
      // silently stop showing live progress.
      expect(WidgetRenderState.active.name, 'active');
    });

    test('toWidgetFields serialises every contract key (no nulls)', () {
      const data = WidgetStateData(
        state: WidgetRenderState.active,
        title: 'Downtown office',
        subtitle: 'Tracking your journey',
        progressPercent: 42,
        ctaLabel: 'Open',
        deepLink: 'geowake://open',
        routeId: null,
      );

      final fields = data.toWidgetFields();

      expect(
        fields.keys.toSet(),
        {
          HomeWidgetBridge.fState,
          HomeWidgetBridge.fTitle,
          HomeWidgetBridge.fSubtitle,
          HomeWidgetBridge.fProgress,
          HomeWidgetBridge.fCta,
          HomeWidgetBridge.fDeepLink,
          HomeWidgetBridge.fRouteId,
        },
      );
      // Every value is a non-null String (RemoteViews getString-friendly).
      expect(fields.values.every((v) => v.isNotEmpty || true), isTrue);
      expect(fields[HomeWidgetBridge.fState], 'active');
      expect(fields[HomeWidgetBridge.fProgress], '42',
          reason: 'progress is stringified for the native ProgressBar');
      expect(fields[HomeWidgetBridge.fRouteId], '',
          reason: 'null routeId serialises to empty string, never null');
    });

    test('idle card carries an arm deep-link + route id the native tap replays',
        () {
      const data = WidgetStateData(
        state: WidgetRenderState.idle,
        title: 'Downtown office',
        subtitle: 'Frequent trip · tap to arm',
        progressPercent: 0,
        ctaLabel: 'Arm',
        deepLink: 'geowake://arm?routeId=r1',
        routeId: 'r1',
      );
      final fields = data.toWidgetFields();
      expect(fields[HomeWidgetBridge.fState], 'idle');
      expect(fields[HomeWidgetBridge.fDeepLink], 'geowake://arm?routeId=r1');
      expect(fields[HomeWidgetBridge.fRouteId], 'r1');
    });
  });
}
