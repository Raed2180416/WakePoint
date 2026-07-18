import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/share/share_deep_link.dart';

void main() {
  test('parses https App Link with token', () {
    final l = ShareDeepLinkParser.parseString('https://geo.wake/j/ABC?t=tok');
    expect(l, isNotNull);
    expect(l!.id, 'ABC');
    expect(l.token, 'tok');
  });

  test('parses https App Link without token', () {
    final l = ShareDeepLinkParser.parseString('https://geo.wake/j/XYZ');
    expect(l!.id, 'XYZ');
    expect(l.token, isNull);
  });

  test('parses custom scheme geowake://j/{id}', () {
    final l = ShareDeepLinkParser.parseString('geowake://j/ID1?t=t2');
    expect(l!.id, 'ID1');
    expect(l.token, 't2');
  });

  test('returns null for non-share urls and junk', () {
    expect(ShareDeepLinkParser.parseString('https://geo.wake/about'), isNull);
    expect(ShareDeepLinkParser.parseString('https://geo.wake/j/'), isNull);
    expect(ShareDeepLinkParser.parseString(''), isNull);
    expect(ShareDeepLinkParser.parse(null), isNull);
  });
}
