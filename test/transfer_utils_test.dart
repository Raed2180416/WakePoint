import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/transfer_utils.dart';

void main() {
  test('TransferUtils detects transfer boundaries for consecutive transit steps on different lines', () {
    final directions = {
      'routes': [
        {
          'legs': [
            {
              'steps': [
                {
                  'travel_mode': 'TRANSIT',
                  'distance': {'value': 800},
                  'transit_details': {
                    'line': {'short_name': 'A'}
                  }
                },
                {
                  'travel_mode': 'TRANSIT',
                  'distance': {'value': 1200},
                  'transit_details': {
                    'line': {'short_name': 'B'}
                  }
                },
                {
                  'travel_mode': 'TRANSIT',
                  'distance': {'value': 1000},
                  'transit_details': {
                    'line': {'short_name': 'B'}
                  }
                },
              ]
            }
          ]
        }
      ]
    };

    final boundaries = TransferUtils.buildTransferBoundariesMeters(directions, metroMode: true);
  expect(boundaries.length, 1);
  expect(boundaries.first, 800); // boundary at end of current A step before switching to B
  });

  test('TransferUtils detects transfer boundaries with walking segments between lines', () {
    final directions = {
      'routes': [
        {
          'legs': [
            {
              'steps': [
                {
                  'travel_mode': 'TRANSIT',
                  'distance': {'value': 500},
                  'transit_details': {
                    'line': {'short_name': 'X'}
                  }
                },
                {
                  'travel_mode': 'WALKING',
                  'distance': {'value': 200},
                },
                {
                  'travel_mode': 'TRANSIT',
                  'distance': {'value': 400},
                  'transit_details': {
                    'line': {'short_name': 'Y'}
                  }
                },
              ]
            }
          ]
        }
      ]
    };
    final boundaries = TransferUtils.buildTransferBoundariesMeters(directions, metroMode: true);
    expect(boundaries.length, 1);
    expect(boundaries.first, 500); // boundary at end of first transit step (X -> Y after walking)
  });
}
