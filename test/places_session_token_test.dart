import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/api_client.dart';
import 'package:geowake2/services/places_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('PlacesService reuses session token for autocomplete and place details', () async {
    ApiClient.testMode = true;
    final places = PlacesService();

    // Autocomplete
    await places.fetchAutocompleteResults('test', countryCode: 'US');
    final token1 = ApiClient.lastAutocompleteBody?['sessiontoken'];
    expect(token1, isNotNull);

    // Place details (same session)
    await places.fetchPlaceDetails('test_place_id');
    final token2 = ApiClient.lastPlaceDetailsBody?['sessiontoken'];
    expect(token2, equals(token1));
  });
}
