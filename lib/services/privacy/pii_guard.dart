// lib/services/privacy/pii_guard.dart
//
// Shared PII / coordinate scanner for GeoWake's privacy-by-construction
// surfaces. Extracted from `post_arrival_service.dart`'s inline patterns so the
// trip-stats ledger (and any future local-first surface) reuses the exact same,
// already-reviewed regexes rather than growing a second, drifting copy.
//
// This module is PURE (no Flutter, no I/O) so it is trivially unit-testable and
// safe to import from a background isolate. It never echoes the offending value
// in an error, so the guard itself cannot leak the data it rejects.
library;

/// Thrown when a would-be user-facing / persisted field carries coordinate- or
/// PII-looking content. Names the *field* and *reason* only — never the value.
class PiiViolation extends Error {
  final String field;
  final String reason;

  PiiViolation(this.field, this.reason);

  @override
  String toString() =>
      'PiiViolation: "$field" must carry no coordinates or PII ($reason)';
}

/// Internal (pattern, human-readable reason) pair.
class _PiiPattern {
  final RegExp pattern;
  final String reason;
  const _PiiPattern(this.pattern, this.reason);
}

/// Stateless scanner for coordinate/PII-looking strings.
class PiiGuard {
  const PiiGuard._();

  /// Patterns that indicate a field is leaking a coordinate or PII. Kept
  /// byte-for-byte in sync with `PostArrivalCard._piiPatterns`.
  static final List<_PiiPattern> _patterns = <_PiiPattern>[
    // "12.9716, 77.5946" — a decimal-degree pair.
    _PiiPattern(
      RegExp(r'-?\d{1,3}\.\d{3,}\s*[,;]\s*-?\d{1,3}\.\d{3,}'),
      'looks like a coordinate pair',
    ),
    // A lone high-precision decimal degree ("12.97159") — ~metre precision a
    // place *name* would never carry.
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

  /// True iff [value] contains no coordinate/PII-looking content.
  static bool isClean(String value) {
    for (final p in _patterns) {
      if (p.pattern.hasMatch(value)) return false;
    }
    return true;
  }

  /// Throws [PiiViolation] if [value] carries coordinate/PII-looking content.
  static void assertClean(String field, String value) {
    for (final p in _patterns) {
      if (p.pattern.hasMatch(value)) {
        throw PiiViolation(field, p.reason);
      }
    }
  }

  /// Assert a nullable field (no-op when null).
  static void assertCleanNullable(String field, String? value) {
    if (value != null) assertClean(field, value);
  }
}
