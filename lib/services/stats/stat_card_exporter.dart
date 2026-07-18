// lib/services/stats/stat_card_exporter.dart
//
// Renders a [ShareStatCard] RepaintBoundary to a PNG and hands it to the OS
// share sheet via share_plus. USER-INITIATED ONLY — the only egress the trip
// ledger ever performs, and it is an image the user explicitly chose to share.
//
// Everything is wrapped so a render/encode/share failure degrades to a
// [StatCardExportStatus.failed] result and never throws into the UI. The render
// is capped at pixelRatio 2.0 (1080×1350 for the 540×675 card) to avoid the
// OOM-prone multi-megapixel RGBA buffer a higher ratio would allocate on budget
// India devices.
library;

import 'dart:developer' as dev;
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

enum StatCardExportStatus { shared, failed, unsupportedContext }

class StatCardExportResult {
  final StatCardExportStatus status;
  final String? filePath;
  const StatCardExportResult(this.status, {this.filePath});

  bool get isSuccess => status == StatCardExportStatus.shared;
}

class StatCardExporter {
  const StatCardExporter._();

  /// Default export ratio. 2.0 → 1080×1350 for the 540×675 logical card.
  static const double defaultPixelRatio = 2.0;

  /// Render the boundary at [boundaryKey] to PNG bytes. Returns null on any
  /// failure (boundary not mounted, still painting, encode error).
  static Future<Uint8List?> renderToPngBytes(
    GlobalKey boundaryKey, {
    double pixelRatio = defaultPixelRatio,
  }) async {
    try {
      final ctx = boundaryKey.currentContext;
      final obj = ctx?.findRenderObject();
      if (obj is! RenderRepaintBoundary) return null;
      final ui.Image image = await obj.toImage(pixelRatio: pixelRatio);
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        return data?.buffer.asUint8List();
      } finally {
        image.dispose();
      }
    } catch (e) {
      dev.log('renderToPngBytes failed: $e', name: 'StatCardExporter');
      return null;
    }
  }

  /// Render + share. [subject]/[text] carry only generic, PII-free copy.
  static Future<StatCardExportResult> shareCard(
    GlobalKey boundaryKey, {
    double pixelRatio = defaultPixelRatio,
    String text = 'GeoWake never lets me miss my stop.',
  }) async {
    try {
      final bytes = await renderToPngBytes(boundaryKey, pixelRatio: pixelRatio);
      if (bytes == null || bytes.isEmpty) {
        return const StatCardExportResult(StatCardExportStatus.failed);
      }
      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}${Platform.pathSeparator}geowake_stats_${DateTime.now().millisecondsSinceEpoch}.png';
      final file = File(path);
      await file.writeAsBytes(bytes, flush: true);

      await Share.shareXFiles(
        [XFile(path, mimeType: 'image/png')],
        text: text,
      );
      return StatCardExportResult(StatCardExportStatus.shared, filePath: path);
    } catch (e) {
      dev.log('shareCard failed: $e', name: 'StatCardExporter');
      return const StatCardExportResult(StatCardExportStatus.failed);
    }
  }
}
