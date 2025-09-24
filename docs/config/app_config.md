# app_config.dart

- Secures API usage by throwing on direct API key access; all calls go through server via ApiClient.
- `apiKeySource` returns descriptive source string.
- `serverBaseUrl` and `appBundleId` constants.
