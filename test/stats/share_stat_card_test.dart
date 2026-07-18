import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/stats/stat_card_exporter.dart';
import 'package:geowake2/widgets/stats/share_stat_card.dart';

void main() {
  testWidgets('ShareStatCard renders the headline count and brand', (t) async {
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ShareStatCard(data: ShareStatCardData.monthlyHeadline(47)),
        ),
      ),
    );
    expect(find.text('47'), findsOneWidget);
    expect(find.text('GeoWake'), findsOneWidget);
    expect(
      find.text('made with GeoWake · never miss your stop'),
      findsOneWidget,
    );
  });

  testWidgets('renderToPngBytes produces non-empty PNG bytes', (t) async {
    final key = GlobalKey();
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RepaintBoundary(
            key: key,
            child: ShareStatCard(data: ShareStatCardData.monthlyHeadline(12)),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();

    // toImage drives the real engine rasterizer, so it must run under the real
    // event loop (not the fake test clock).
    final bytes = await t.runAsync(
      () => StatCardExporter.renderToPngBytes(key, pixelRatio: 2.0),
    );
    expect(bytes, isNotNull);
    expect(bytes!.length, greaterThan(1000));
    // PNG magic number.
    expect(bytes.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
  });

  testWidgets('renderToPngBytes returns null for an unmounted boundary',
      (t) async {
    final orphanKey = GlobalKey();
    final bytes = await StatCardExporter.renderToPngBytes(orphanKey);
    expect(bytes, isNull);
  });
}
