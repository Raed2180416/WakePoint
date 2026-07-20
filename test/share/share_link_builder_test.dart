// Pure tests for ShareLinkBuilder — message/URL format is load-bearing (the
// viral loop) and must stay exactly "GeoWake" + PII-free, and the HMAC token
// must round-trip and reject tampering.
import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/share/share_link_builder.dart';

void main() {
  group('share message', () {
    test('exact format with ETA, says GeoWake, carries no PII', () {
      final url = ShareLinkBuilder.buildShareUrl(
        'abc123',
        domain: 'https://geo.wake',
      );
      final eta = DateTime(2026, 7, 19, 8, 42);
      final msg = ShareLinkBuilder.buildBasicMessage(
        url: url,
        eta: eta,
        destLabel: 'Nallur Halli',
      );

      expect(msg, 'On my way to Nallur Halli — arriving ~8:42 · GeoWake\n$url');
      expect(msg.contains('GeoWake'), isTrue);
      // No coordinates / names leaked into the message.
      expect(RegExp(r'\d{1,3}\.\d{3,}').hasMatch(msg), isFalse);
      expect(msg.contains('WakePoint'), isFalse);
      expect(msg.contains('geowake2'), isFalse);
    });

    test('no-ETA form still says GeoWake', () {
      final url = ShareLinkBuilder.buildShareUrl('x');
      final msg = ShareLinkBuilder.buildBasicMessage(url: url);
      expect(msg, 'On my way · GeoWake\n$url');
    });

    test('arrived message says GeoWake and is safe', () {
      expect(
        ShareLinkBuilder.buildArrivedMessage(destLabel: 'Indiranagar'),
        "I've arrived safely at Indiranagar · GeoWake",
      );
      expect(
        ShareLinkBuilder.buildArrivedMessage(),
        "I've arrived safely · GeoWake",
      );
    });

    test('formatEta pads minutes, 24h hour, local', () {
      expect(ShareLinkBuilder.formatEta(DateTime(2026, 1, 1, 8, 2)), '8:02');
      expect(ShareLinkBuilder.formatEta(DateTime(2026, 1, 1, 14, 5)), '14:05');
    });
  });

  group('urls', () {
    test('share url shape /j/{id} with token', () {
      final u = ShareLinkBuilder.buildShareUrl(
        'ID9',
        domain: 'https://geo.wake',
        token: 'tok',
      );
      expect(u, 'https://geo.wake/j/ID9?t=tok');
    });

    test('trailing slash in domain is normalised', () {
      final u = ShareLinkBuilder.buildShareUrl(
        'ID9',
        domain: 'https://geo.wake/',
      );
      expect(u, 'https://geo.wake/j/ID9');
    });

    test('install fallback carries referrer', () {
      final u = ShareLinkBuilder.buildInstallFallbackUrl('S1');
      expect(u.contains('referrer=share_S1'), isTrue);
      expect(u.contains('com.geowake.app'), isTrue);
    });
  });

  group('token', () {
    test('round-trips', () {
      const secret = 'super-secret-key';
      final t = ShareLinkBuilder.mintToken('id-1', secret);
      expect(ShareLinkBuilder.verifyToken('id-1', t, secret), isTrue);
    });

    test('rejects tampered id, token, or secret', () {
      const secret = 'super-secret-key';
      final t = ShareLinkBuilder.mintToken('id-1', secret);
      expect(ShareLinkBuilder.verifyToken('id-2', t, secret), isFalse);
      expect(ShareLinkBuilder.verifyToken('id-1', '${t}x', secret), isFalse);
      expect(ShareLinkBuilder.verifyToken('id-1', t, 'other'), isFalse);
    });
  });
}
