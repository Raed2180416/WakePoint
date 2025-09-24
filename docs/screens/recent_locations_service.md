# recent_locations_service.dart

RecentLocationsService (line-by-line)

Purpose: Persist and retrieve recent locations with resilience.

- `_ensureBoxIsOpen()`: opens Hive box; on failure (likely corruption) deletes and recreates, then reopens; logs all steps.
- `getRecentLocations()`: returns normalized `List<Map<String,dynamic>>` or empty list; logs counts/errors.
- `saveRecentLocations()`: writes list and `flush()`es to disk immediately to reduce data loss on termination.
