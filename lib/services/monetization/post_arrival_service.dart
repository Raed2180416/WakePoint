/// Post-arrival contextual card — GeoWake's flagship "last-mile-intent"
/// monetization surface (MONETIZATION.md §C).
///
/// The instant a rider steps off transit they have a real, high-value need:
/// getting from the *station* to their *actual* destination. GeoWake owns that
/// moment. A single native card shown **after the wake alarm is dismissed** —
/// "You've arrived at Indiranagar" + "Book a ride from the station" — monetizes
/// that *intent* at an estimated 10–50× the value of an ad *impression*, and it
/// does so by serving a genuine need, so it reads as a feature, not a tax.
///
/// This file is the **model + logic only**; the Flutter widget is built at
/// integration. It is deliberately pure and headless: no platform channels, no
/// ad/affiliate SDK, no location APIs. Nearby last-mile options are *injected*
/// as already-resolved [LastMileOption]s (a display label + a generic kind,
/// never coordinates), so the monetization layer never touches raw geometry.
///
/// PRIVACY INVARIANT (HANDOFF §4 — k-anonymous, aggregate-only): the card model
/// carries **no coordinates and no PII** — only the station name/zone and
/// generic action kinds. [PostArrivalCard.validate] is a defensive assertion
/// path that throws if any coordinate- or PII-looking content ever leaks into a
/// user-facing (or telemetry-bound) field. [PostArrivalService.build] runs it
/// at construction so a bad input fails loudly here instead of shipping to the
/// UI, the ad network, or the mobility-data aggregation pipeline.
library;

/// An injected, already-resolved last-mile option.
///
/// Deliberately carries only a display [label] and a generic [kind] — **never**
/// coordinates. Resolving a place to a label (and stripping its location)
/// happens *outside* this module, upstream of the privacy boundary, so the
/// monetization layer only ever sees names + kinds. [kind] should be one of the
/// secondary [PostArrivalActionKind] values (`food`/`directions`); anything
/// else is ignored by [PostArrivalService.build].
class LastMileOption {
  final String label;
  final String kind;

  const LastMileOption({required this.label, required this.kind});
}

/// The closed set of allowed [PostArrivalAction.kind] values.
///
/// Kept as plain strings (not an enum) so the card model serialises trivially
/// and stays dependency-free, but the set is closed and validated.
class PostArrivalActionKind {
  const PostArrivalActionKind._();

  /// Primary CTA: last-mile ride-hailing (Rapido / Ola / Uber). Per
  /// MONETIZATION.md §C this is both the highest-value action *and* the one
  /// that serves the user's actual need, so it is always present and primary.
  static const String rideHailing = 'rideHailing';

  /// Nearby food / coffee (Swiggy / Zomato / local merchants).
  static const String food = 'food';

  /// Walking / driving directions onward from the station.
  static const String directions = 'directions';

  /// Escape hatch — dismiss the card. Always present, never primary.
  static const String dismiss = 'dismiss';

  static const Set<String> values = {rideHailing, food, directions, dismiss};

  static bool isValid(String kind) => values.contains(kind);
}

/// One tappable action on the post-arrival card.
///
/// [kind] is a generic bucket (see [PostArrivalActionKind]); [label] is the
/// user-facing text. Neither may carry coordinates or PII — enforced by
/// [PostArrivalCard.validate].
class PostArrivalAction {
  final String label;
  final String kind;

  /// True for the single primary CTA (the ride-hailing action). Drives visual
  /// emphasis at integration; there is at most one primary action per card.
  final bool isPrimary;

  const PostArrivalAction({
    required this.label,
    required this.kind,
    this.isPrimary = false,
  });

  /// Telemetry-safe projection — kind + primary flag only, never the label
  /// (labels are generic today, but this keeps aggregate events kind-only).
  Map<String, dynamic> toMap() => {
        'kind': kind,
        'isPrimary': isPrimary,
      };

  @override
  String toString() => 'PostArrivalAction(kind: $kind, primary: $isPrimary)';
}

/// Thrown when a would-be card field carries coordinate- or PII-looking
/// content. The message intentionally names the *field* and *reason* only — it
/// never echoes the offending value, so the guard itself cannot leak the data
/// it is rejecting.
class PostArrivalPrivacyError extends Error {
  final String field;
  final String reason;

  PostArrivalPrivacyError(this.field, this.reason);

  @override
  String toString() =>
      'PostArrivalPrivacyError: "$field" must carry no coordinates or PII '
      '($reason)';
}

/// The immutable model rendered as the post-arrival card. Carries only a
/// [title], a coarse [stationName]/[city] (name/zone, never coordinates) and a
/// list of generic [actions].
class PostArrivalCard {
  final String title;

  /// Coarse station/zone name — the *only* location field, and a name, never a
  /// coordinate. Ties to the k-anonymous "station/zone granularity" rule.
  final String stationName;

  /// Optional coarse city/zone label. Never a coordinate.
  final String? city;

  final List<PostArrivalAction> actions;

  const PostArrivalCard({
    required this.title,
    required this.stationName,
    this.city,
    required this.actions,
  });

  /// The single primary CTA (ride-hailing), or null if none is flagged.
  PostArrivalAction? get primaryAction {
    for (final a in actions) {
      if (a.isPrimary) return a;
    }
    return null;
  }

  /// Patterns that indicate a user-facing field is leaking a coordinate or PII.
  /// Order matters only for the *reason* reported; any match rejects the card.
  static final List<_PiiPattern> _piiPatterns = <_PiiPattern>[
    // "12.9716, 77.5946" — a decimal-degree pair.
    _PiiPattern(
      RegExp(r'-?\d{1,3}\.\d{3,}\s*[,;]\s*-?\d{1,3}\.\d{3,}'),
      'looks like a coordinate pair',
    ),
    // A lone high-precision decimal degree ("12.97159") — ~metre precision that
    // a place *name* would never contain.
    _PiiPattern(
      RegExp(r'-?\d{1,3}\.\d{4,}'),
      'looks like a decimal coordinate',
    ),
    // A leaked coordinate field name.
    _PiiPattern(
      RegExp(r'\b(?:lat|lng|latitude|longitude)\b', caseSensitive: false),
      'contains a coordinate field name',
    ),
    // An email address.
    _PiiPattern(
      RegExp(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'),
      'looks like an email address',
    ),
    // A long digit run — phone number / device or user id.
    _PiiPattern(
      RegExp(r'\d{7,}'),
      'looks like a phone or id number',
    ),
  ];

  /// Assert the privacy invariant. Throws [PostArrivalPrivacyError] if any
  /// user-facing string carries coordinate- or PII-looking content, and
  /// [ArgumentError] if an action carries an unrecognised [kind]. Call before
  /// showing the card or emitting any telemetry derived from it.
  void validate() {
    _assertClean('title', title);
    _assertClean('stationName', stationName);
    final c = city;
    if (c != null) _assertClean('city', c);
    for (var i = 0; i < actions.length; i++) {
      final a = actions[i];
      if (!PostArrivalActionKind.isValid(a.kind)) {
        throw ArgumentError.value(
          a.kind,
          'actions[$i].kind',
          'unrecognised post-arrival action kind',
        );
      }
      _assertClean('actions[$i].label', a.label);
    }
  }

  static void _assertClean(String field, String value) {
    for (final p in _piiPatterns) {
      if (p.pattern.hasMatch(value)) {
        throw PostArrivalPrivacyError(field, p.reason);
      }
    }
  }

  /// Telemetry-safe projection. Emits only the coarse name/zone + kind-level
  /// action breakdown — no coordinates, no labels beyond the title/station,
  /// which are themselves validated PII-free.
  Map<String, dynamic> toMap() => {
        'title': title,
        'stationName': stationName,
        'city': city,
        'actions': actions.map((a) => a.toMap()).toList(),
      };

  @override
  String toString() =>
      'PostArrivalCard(station: $stationName, actions: ${actions.length})';
}

/// Builds and gates the post-arrival contextual card.
///
/// Stateless and pure: [build] turns a station name + injected nearby options
/// into a validated [PostArrivalCard]; [shouldShow] gates the card behind the
/// wake alarm so it can never compete with the alarm itself.
class PostArrivalService {
  const PostArrivalService._();

  /// Gate: the card must **never** appear during the wake alarm itself. The
  /// alarm's only job is to wake the rider; nothing may compete with, delay, or
  /// obscure it (HANDOFF §2 — "Never ... anything that could delay/obscure the
  /// alarm"). Returns false until the wake alarm has been dismissed.
  static bool shouldShow({required bool alarmDismissed}) => alarmDismissed;

  /// Build the post-arrival card for a station.
  ///
  /// The ride-hailing CTA is always synthesised as the primary action (§C).
  /// Injected [nearby] options are appended as secondary actions — only
  /// recognised secondary kinds (`food`/`directions`) with a non-empty label
  /// are kept, and any injected ride-hailing option is dropped as a duplicate
  /// of the primary CTA. A [PostArrivalActionKind.dismiss] action is always
  /// appended last. The returned card is [PostArrivalCard.validate]d before it
  /// is returned, so a coordinate/PII-looking input throws here rather than
  /// leaking downstream.
  static PostArrivalCard build({
    required String stationName,
    String? city,
    List<LastMileOption>? nearby,
  }) {
    final station = stationName.trim();
    final trimmedCity = city?.trim();

    final actions = <PostArrivalAction>[
      // Primary CTA — the last-mile ride-hailing intent (MONETIZATION §C).
      const PostArrivalAction(
        label: 'Book a ride from the station',
        kind: PostArrivalActionKind.rideHailing,
        isPrimary: true,
      ),
    ];

    if (nearby != null) {
      for (final option in nearby) {
        final kind = option.kind;
        // The primary already owns the ride-hailing intent — never duplicate.
        if (kind == PostArrivalActionKind.rideHailing) continue;
        // Only recognised *secondary* kinds are surfaced.
        if (kind != PostArrivalActionKind.food &&
            kind != PostArrivalActionKind.directions) {
          continue;
        }
        final label = option.label.trim();
        if (label.isEmpty) continue;
        actions.add(PostArrivalAction(label: label, kind: kind));
      }
    }

    // Dismiss is always available and always last — the card must be trivially
    // escapable at a time-pressured, just-off-the-train moment.
    actions.add(
      const PostArrivalAction(
        label: 'Not now',
        kind: PostArrivalActionKind.dismiss,
      ),
    );

    final title =
        station.isEmpty ? "You've arrived" : "You've arrived at $station";

    final card = PostArrivalCard(
      title: title,
      stationName: station,
      city: (trimmedCity == null || trimmedCity.isEmpty) ? null : trimmedCity,
      actions: actions,
    );

    // Enforce the privacy invariant at construction.
    card.validate();
    return card;
  }
}

/// Internal (pattern, human-readable reason) pair for privacy scanning.
class _PiiPattern {
  final RegExp pattern;
  final String reason;

  const _PiiPattern(this.pattern, this.reason);
}
