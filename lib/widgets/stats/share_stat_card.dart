// lib/widgets/stats/share_stat_card.dart
//
// The FREE viral render target — a branded, PII-free stat card the user shares
// as an IMAGE. Rendered off-screen inside a RepaintBoundary and exported at
// pixelRatio 2.0 (see stat_card_exporter.dart), so the logical 540×675 canvas
// becomes a 1080×1350 PNG (portrait, social-friendly) WITHOUT the ~52MB RGBA
// buffer a 3.0 ratio on a 1080-wide card would allocate on budget devices.
//
// The default template is STATION-FREE ("GeoWake woke me for my stop 47 times
// this month") — no place names, no coordinates, nothing to review. The
// "made with GeoWake" footer is non-removable by construction (it is drawn by
// this widget, not passed in).
//
// Uses only bundled/system fonts — deliberately NOT google_fonts, whose runtime
// network fetch could blank the card when rendered offline.
library;

import 'package:flutter/material.dart';

/// Immutable data for the card. All fields are coarse and PII-free; the default
/// factory keeps the template station-free.
class ShareStatCardData {
  /// The big number (e.g. on-time wakes this month).
  final int count;

  /// Headline line under the number (e.g. "on-time wake-ups").
  final String headline;

  /// Period / context line (e.g. "this month").
  final String period;

  /// Optional secondary stat line (e.g. "Longest streak: 12 days"). Keep it
  /// name-free; callers should not pass station names into the default card.
  final String? subline;

  const ShareStatCardData({
    required this.count,
    this.headline = 'on-time wake-ups',
    this.period = 'this month',
    this.subline,
  });

  /// The default growth-loop card: "GeoWake woke me for my stop N times ...".
  factory ShareStatCardData.monthlyHeadline(int count) => ShareStatCardData(
        count: count,
        headline: 'times GeoWake woke me\nfor my stop',
        period: 'this month',
      );
}

/// Fixed logical size of the card. Exported at pixelRatio 2.0 → 1080×1350 px.
const double kShareCardLogicalWidth = 540;
const double kShareCardLogicalHeight = 675;

/// The card. Wrap in a RepaintBoundary with a GlobalKey to export it.
class ShareStatCard extends StatelessWidget {
  final ShareStatCardData data;

  const ShareStatCard({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    // Self-contained theme — the card must look identical regardless of the
    // host app's light/dark mode, since it becomes a static image.
    const bgTop = Color(0xFF0E7C66); // GeoWake teal-green
    const bgBottom = Color(0xFF0A5C74);
    const onBg = Colors.white;

    return SizedBox(
      width: kShareCardLogicalWidth,
      height: kShareCardLogicalHeight,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [bgTop, bgBottom],
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(40, 44, 40, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Brand lockup.
              Row(
                children: const [
                  Icon(Icons.alarm_on_rounded, color: onBg, size: 34),
                  SizedBox(width: 10),
                  Text(
                    'GeoWake',
                    style: TextStyle(
                      color: onBg,
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.2,
                    ),
                  ),
                ],
              ),
              const Spacer(),
              // The hero number.
              Text(
                '${data.count}',
                style: const TextStyle(
                  color: onBg,
                  fontSize: 150,
                  height: 1.0,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -2,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                data.headline,
                style: const TextStyle(
                  color: onBg,
                  fontSize: 30,
                  height: 1.15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                data.period,
                style: TextStyle(
                  color: onBg.withValues(alpha: 0.85),
                  fontSize: 22,
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (data.subline != null) ...[
                const SizedBox(height: 18),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: onBg.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    data.subline!,
                    style: const TextStyle(
                      color: onBg,
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
              const Spacer(),
              // Non-removable footer.
              Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: onBg.withValues(alpha: 0.9),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'made with GeoWake · never miss your stop',
                      style: TextStyle(
                        color: onBg.withValues(alpha: 0.9),
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
