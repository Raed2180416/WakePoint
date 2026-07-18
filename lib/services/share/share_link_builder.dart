// lib/services/share/share_link_builder.dart
//
// PURE, no-I/O construction of the share text, the App-Links URL, the install
// fallback URL, and the HMAC token that makes a `/j/{id}` link unguessable /
// tamper-evident. Every message says "GeoWake" and carries NO PII (no names,
// no coordinates) — only the opaque session id.
//
// Kept pure so it is exhaustively unit-testable with zero device/network/plugin
// dependencies.

import 'dart:convert';

import 'package:crypto/crypto.dart';

class ShareLinkBuilder {
  const ShareLinkBuilder._();

  /// Default App-Links domain. The founder swaps this for the real registered
  /// domain (with `/.well-known/assetlinks.json`) when the backend ships.
  static const String defaultDomain = 'https://geo.wake';

  /// Android package id (for the Play install-referrer fallback link).
  static const String androidPackage = 'com.example.geowake2';

  /// The `/j/{id}` share URL a recipient opens.
  ///
  /// [token] (optional) is appended as `?t=` so the recipient page / backend can
  /// verify the link was minted by this device and hasn't been altered.
  static String buildShareUrl(
    String id, {
    String domain = defaultDomain,
    String? token,
  }) {
    final base = '${_stripTrailingSlash(domain)}/j/$id';
    if (token == null || token.isEmpty) return base;
    return '$base?t=${Uri.encodeComponent(token)}';
  }

  /// A Play-Store link carrying the share id as an install referrer, so a
  /// recipient WITHOUT the app still lands attributed after installing.
  static String buildInstallFallbackUrl(
    String id, {
    String package = androidPackage,
  }) {
    final referrer = Uri.encodeComponent('share_$id');
    return 'https://play.google.com/store/apps/details'
        '?id=$package&referrer=$referrer';
  }

  /// The share message. EXACT format (test-enforced):
  ///   `Track my journey — arriving ~h:mm · GeoWake\n<url>`
  /// When no ETA is known the "arriving" clause is dropped but "GeoWake" stays.
  static String buildBasicMessage({
    required String url,
    DateTime? eta,
  }) {
    if (eta == null) {
      return 'Track my journey · GeoWake\n$url';
    }
    return 'Track my journey — arriving ~${formatEta(eta)} · GeoWake\n$url';
  }

  /// The "arrived safely" message Guardian sends to the saved contact.
  static String buildArrivedMessage({String? destLabel}) {
    final where = (destLabel != null && destLabel.trim().isNotEmpty)
        ? ' at ${destLabel.trim()}'
        : '';
    return 'I\'ve arrived safely$where · GeoWake';
  }

  /// `h:mm` in local time (e.g. `8:42`, `14:05`).
  static String formatEta(DateTime dt) {
    final local = dt.toLocal();
    final mm = local.minute.toString().padLeft(2, '0');
    return '${local.hour}:$mm';
  }

  // --- Tamper-evident token (HMAC-SHA256 over the id) ------------------------

  /// Mint a hex HMAC-SHA256 token binding [id] to [secret].
  static String mintToken(String id, String secret) {
    final hmac = Hmac(sha256, utf8.encode(secret));
    return hmac.convert(utf8.encode(id)).toString();
  }

  /// Constant-time-ish verification that [token] was minted for [id]/[secret].
  static bool verifyToken(String id, String token, String secret) {
    final expected = mintToken(id, secret);
    if (expected.length != token.length) return false;
    var diff = 0;
    for (var i = 0; i < expected.length; i++) {
      diff |= expected.codeUnitAt(i) ^ token.codeUnitAt(i);
    }
    return diff == 0;
  }

  static String _stripTrailingSlash(String s) =>
      s.endsWith('/') ? s.substring(0, s.length - 1) : s;
}
