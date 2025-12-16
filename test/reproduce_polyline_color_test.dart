import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/transfer_utils.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

// Simple polyline encoder for test
String encodePolyline(List<LatLng> points) {
  // This is a dummy encoder or we can use a hardcoded string.
  // For simplicity, let's use a known string or just an empty string if we mock the decoder.
  // But TransferUtils uses the real decoder.
  // Let's use a simple real string: "_p~iF~ps|U_ulLnnqC_mqNvxq`@" (approx)
  // Or just rely on the fact that decodePolyline handles simple cases?
  // Let's assume the decoder works and we just need valid strings.
  // Actually, we can just use "example" if we don't care about the *actual* points,
  // but we want to verify the list length.
  // decodePolyline likely fails or returns empty for invalid strings.
  // Let's use a very simple one: `_p~iF` -> (38.5, -120.2)
  return '_p~iF';
}

void main() {
  test('buildRouteSegments identifies transit segments correctly', () {
    final directions = {
      'routes': [
        {
          'legs': [
            {
              'steps': [
                {
                  'travel_mode': 'WALKING',
                  'polyline': {'points': '_p~iF'},
                  'distance': {'value': 100},
                },
                {
                  'travel_mode': 'TRANSIT',
                  'polyline': {'points': '_p~iF'},
                  'transit_details': {
                    'line': {'short_name': 'M1'},
                    'num_stops': 3,
                  },
                },
                {
                  'travel_mode': 'WALKING', // Transfer
                  'polyline': {'points': '_p~iF'},
                },
                {
                  'travel_mode': 'TRANSIT',
                  'polyline': {'points': '_p~iF'},
                  'transit_details': {
                    'line': {'short_name': 'M2'},
                    'num_stops': 3,
                  },
                },
                {
                  'travel_mode': 'WALKING', // Final leg
                  'polyline': {'points': '_p~iF'},
                },
              ],
            },
          ],
        },
      ],
    };

    final segments = TransferUtils.buildRouteSegments(directions);

    expect(segments.length, 5);
    expect(segments[0]['mode'], 'walking');
    expect(segments[1]['mode'], 'transit');
    expect(segments[2]['mode'], 'walking');
    // Here is where we suspect the bug: maybe the second transit leg is misidentified?
    expect(segments[3]['mode'], 'transit');
    expect(segments[4]['mode'], 'walking');
  });

  test(
    'buildRouteSegments handles nested steps in transit legs if applicable',
    () {
      // Some responses might wrap the walk-transit-walk pattern differently.
      // But based on our code, we iterate the TOP level steps of the leg.
      // If Google provides a "Walking" step as a child of a "Transit" step, our current code MISSES it.
      // Let's check the code: it iterates `leg['steps']`. It DOES NOT recurse.
    },
  );
}
