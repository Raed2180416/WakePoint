import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/share/journey_share_models.dart';

void main() {
  test('snapshot rounds coords to 5 dp', () {
    final s = ShareSnapshot(lat: 12.97161234, lng: 77.59468999, atMs: 1000);
    expect(s.lat, 12.97161);
    expect(s.lng, 77.59469);
  });

  test('snapshot has NO trajectory/history field (privacy invariant)', () {
    final json = ShareSnapshot(lat: 1, lng: 2, atMs: 5).toJson();
    expect(json.keys.toSet(), {'lat', 'lng', 'etaEpochMs', 'atMs'});
    for (final v in json.values) {
      expect(v is List, isFalse, reason: 'no array payload allowed');
    }
  });

  test('session json round-trips', () {
    const s = ShareSession(
      id: 'i',
      mode: ShareMode.guardian,
      status: ShareStatus.enRoute,
      createdAtMs: 1,
      expiresAtMs: 2,
      destLabel: 'Stop',
      etaEpochMs: 99,
    );
    final back = ShareSession.decode(s.encode());
    expect(back.id, 'i');
    expect(back.mode, ShareMode.guardian);
    expect(back.status, ShareStatus.enRoute);
    expect(back.destLabel, 'Stop');
    expect(back.etaEpochMs, 99);
  });

  test('session expiry + active semantics', () {
    const s = ShareSession(
      id: 'i',
      mode: ShareMode.basicLink,
      status: ShareStatus.enRoute,
      createdAtMs: 0,
      expiresAtMs: 100,
    );
    expect(s.isActive, isTrue);
    expect(s.isExpiredAt(50), isFalse);
    expect(s.isExpiredAt(100), isTrue);
    expect(s.copyWith(status: ShareStatus.arrived).isActive, isFalse);
  });

  test('unknown enum names decode to safe defaults', () {
    final s = ShareSession.fromJson({
      'id': 'i',
      'mode': 'bogus',
      'status': 'bogus',
      'createdAtMs': 0,
      'expiresAtMs': 1,
    });
    expect(s.mode, ShareMode.basicLink);
    expect(s.status, ShareStatus.enRoute);
  });
}
