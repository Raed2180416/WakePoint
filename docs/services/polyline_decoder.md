# Polyline Decoder (lib/services/polyline_decoder.dart)

Purpose: Decodes encoded polylines into `List<LatLng>`.

- `decodePolyline(encoded)`: line 5 — standard Google algorithm; robust to partial failures (returns points so far on error).

Tests: verified indirectly via DirectionService and SnapToRoute tests.
