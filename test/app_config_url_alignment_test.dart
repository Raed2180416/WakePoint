import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/config/app_config.dart';
import 'package:geowake2/services/api_client.dart';

void main() {
  test(
    'AppConfig server URL should not point to localhost in release builds',
    () {
      // This ensures we do not accidentally ship a localhost URL while ApiClient is production.
      expect(AppConfig.serverBaseUrl.contains('localhost'), isFalse);
      expect(AppConfig.serverBaseUrl.contains('127.0.0.1'), isFalse);
    },
  );

  test(
    'AppConfig server URL should align with ApiClient base URL authority',
    () {
      final appConfigUri = Uri.parse(AppConfig.serverBaseUrl);
      final apiClientUri = Uri.parse(ApiClient.baseUrl);
      expect(appConfigUri.host, apiClientUri.host);
    },
  );
}
