// docs/annotated/services/polyline_decoder.annotated.dart
// Purpose: Line-by-line annotated copy of `lib/services/polyline_decoder.dart`.
// Scope: Explains each statement, control-flow, and data transformation; adds post-block notes and an end-of-file summary.

import 'package:google_maps_flutter/google_maps_flutter.dart'; // Import LatLng type from Google Maps Flutter plugin.

/// Decodes an encoded polyline string into a list of [LatLng] coordinates. // High-level description of function behavior.
/// Returns an empty list if the input is empty or an error occurs.          // Notes failure-safe behavior.
List<LatLng> decodePolyline(String encoded) { // Function signature: takes encoded polyline string; returns list of LatLng.
  if (encoded.isEmpty) { // Guard clause: empty input short-circuits to empty result.
    return []; // Return empty list to avoid processing.
  }
  List<LatLng> polyline = []; // Accumulator list for decoded points.
  int index = 0; // Current read index into the string.
  int len = encoded.length; // Cache total string length for loop bound.
  int lat = 0; // Accumulator for latitude delta decoding (scaled by 1e5).
  int lng = 0; // Accumulator for longitude delta decoding (scaled by 1e5).

  try { // Try/catch to handle malformed strings gracefully.
    while (index < len) { // Main decode loop: reads pairs of varint-encoded deltas until end of string.
      int shift = 0; // Bit shift position for current varint byte sequence (latitude component).
      int result = 0; // Aggregated varint result (latitude component).
      int b; // Temporary byte holder.
      do { // Read bytes until continuation bit clears (b < 0x20 implies last byte).
        b = encoded.codeUnitAt(index++) - 63; // Decode one character: convert ASCII to 6-bit chunk by subtracting 63.
        result |= (b & 0x1F) << shift; // Add lower 5 bits into result at current shift.
        shift += 5; // Advance shift for next chunk.
      } while (b >= 0x20); // Continuation if high bit set (>= 0x20 means more bytes follow).
      int dlat = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1)); // ZigZag decode: LSB sign, arithmetic shift.
      lat += dlat; // Accumulate delta into running latitude sum.

      shift = 0; // Reset for longitude varint.
      result = 0; // Reset aggregated result for longitude.
      do { // Same varint decode loop for longitude component.
        b = encoded.codeUnitAt(index++) - 63; // Read next chunk for longitude.
        result |= (b & 0x1F) << shift; // Merge lower 5 bits.
        shift += 5; // Advance shift.
      } while (b >= 0x20); // Continue until last chunk.
      int dlng = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1)); // ZigZag decode for longitude delta.
      lng += dlng; // Accumulate longitude.

      polyline.add(LatLng(lat / 1E5, lng / 1E5)); // Convert scaled integers back to degrees and append as LatLng.
    }
  } catch (e) { // Any out-of-bounds or format exceptions are caught here.
    // Return the decoded points so far if an error occurs. // Partial tolerance: best-effort decoding.
    return polyline; // Return whatever we decoded before the error.
  }
  return polyline; // Completed decode successfully; return full list.
}

// Post-block notes:
// - This implementation follows Google Encoded Polyline Algorithm Format.
// - Uses ZigZag decoding to recover signed deltas; accumulates to get absolute coordinates.
// - Precision is 1e-5 degrees (~1.1 m), standard for polylines.
// - The function is resilient: it returns partial results on failure, which is preferable for mapping overlays.

// End-of-file summary:
// - Inputs: `encoded` polyline string as per Google directions/places responses.
// - Outputs: Ordered list of `LatLng` points representing the path.
// - Error handling: try/catch returns partially decoded points to avoid total failure.
// - Performance: O(N) over string length; allocations proportional to number of points.
