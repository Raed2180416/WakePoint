// Regression test: PlacesService must end its Google Places session token
// after a Place Details call, per Google's session-token billing rules (a
// token covers exactly one autocomplete-then-details flow). Before the fix,
// PlacesService.endSession() existed but nothing called it, so the same
// session token could be reused for up to 3 more minutes across multiple
// completed (billed) Details calls.

import 'package:flutter_test/flutter_test.dart';

import 'package:geowake2/services/api_client.dart';
import 'package:geowake2/services/places_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    ApiClient.testMode = true;
    ApiClient.lastAutocompleteBody = null;
    ApiClient.lastPlaceDetailsBody = null;
  });

  tearDown(() {
    ApiClient.testMode = false;
  });

  test(
      'fetchPlaceDetails ends the session so the NEXT autocomplete search '
      'starts a fresh session token', () async {
    final places = PlacesService();

    await places.fetchAutocompleteResults('indiranagar');
    final autocompleteToken =
        ApiClient.lastAutocompleteBody!['sessiontoken'] as String;
    expect(autocompleteToken, isNotEmpty);

    await places.fetchPlaceDetails('test_place_id');
    final detailsToken =
        ApiClient.lastPlaceDetailsBody!['sessiontoken'] as String;
    // The Details call reuses the SAME session as its preceding autocomplete
    // search — that part of session billing is correct and must not change.
    expect(detailsToken, autocompleteToken);

    // A search AFTER Details must NOT reuse the now-closed session.
    await places.fetchAutocompleteResults('mg road');
    final nextAutocompleteToken =
        ApiClient.lastAutocompleteBody!['sessiontoken'] as String;
    expect(nextAutocompleteToken, isNot(detailsToken),
        reason: 'a session token must not survive past its Place Details '
            'call — reusing it risks incorrect session billing');
  });

  test('endSession() is safe to call when no session was ever started',
      () async {
    final places = PlacesService();
    expect(() => places.endSession(), returnsNormally);
  });

  test(
      'two independent autocomplete → details flows never share a session '
      'token', () async {
    final places = PlacesService();

    await places.fetchAutocompleteResults('query one');
    await places.fetchPlaceDetails('place_one');
    final firstDetailsToken =
        ApiClient.lastPlaceDetailsBody!['sessiontoken'] as String;

    await places.fetchAutocompleteResults('query two');
    await places.fetchPlaceDetails('place_two');
    final secondDetailsToken =
        ApiClient.lastPlaceDetailsBody!['sessiontoken'] as String;

    expect(secondDetailsToken, isNot(firstDetailsToken));
  });
}
