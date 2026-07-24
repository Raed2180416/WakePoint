// test/services/data_asset/http_candidate_egress_sink_test.dart
//
// Tests for the HttpCandidateEgressSink and NullCandidateEgressSink.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/data_asset/aggregate_schema.dart';
import 'package:geowake2/services/data_asset/http_candidate_egress_sink.dart';
import 'package:geowake2/services/data_asset/od_cell.dart';

void main() {
  group('NullCandidateEgressSink', () {
    test('uploadCandidate completes without error', () async {
      const sink = NullCandidateEgressSink();
      final candidate = ReleaseCandidateMatrix(cells: [
        ReleaseCandidateCell(
          key: OdCellKey(
            originStationId: 'OSM_1',
            destStationId: 'OSM_2',
            hourBin: 8,
            dayType: DayType.weekday,
          ),
          candidateNoisyCount: 5,
          localContributingUsers: 1,
          dpApplied: true,
          epsilon: 0.44,
        ),
      ]);

      // Should complete without throwing.
      await sink.uploadCandidate(candidate);
    });
  });

  group('HttpCandidateEgressSink', () {
    test('is a no-op when kDataAssetEgressEnabled is false', () async {
      // Since kDataAssetEgressEnabled is a compile-time const = false,
      // the sink should be a no-op regardless of endpoint.
      final sink = HttpCandidateEgressSink(
        endpoint: 'http://localhost:9999/api/aggregate',
        tokenProvider: () => 'test-token',
      );

      final candidate = ReleaseCandidateMatrix(cells: [
        ReleaseCandidateCell(
          key: OdCellKey(
            originStationId: 'OSM_1',
            destStationId: 'OSM_2',
            hourBin: 8,
            dayType: DayType.weekday,
          ),
          candidateNoisyCount: 5,
          localContributingUsers: 1,
          dpApplied: true,
          epsilon: 0.44,
        ),
      ]);

      // Should complete without attempting any network call.
      await sink.uploadCandidate(candidate);
    });

    test('is a no-op when endpoint is empty', () async {
      final sink = HttpCandidateEgressSink(
        endpoint: '',
        tokenProvider: () => null,
      );

      final candidate = ReleaseCandidateMatrix(cells: [
        ReleaseCandidateCell(
          key: OdCellKey(
            originStationId: 'OSM_1',
            destStationId: 'OSM_2',
            hourBin: 8,
            dayType: DayType.weekday,
          ),
          candidateNoisyCount: 5,
          localContributingUsers: 1,
          dpApplied: true,
          epsilon: 0.44,
        ),
      ]);

      await sink.uploadCandidate(candidate);
    });
  });

  group('ReleaseCandidateMatrix JSON', () {
    test('serializes correctly for backend ingestion', () {
      final matrix = ReleaseCandidateMatrix(cells: [
        ReleaseCandidateCell(
          key: OdCellKey(
            originStationId: 'OSM_1',
            destStationId: 'OSM_2',
            hourBin: 8,
            dayType: DayType.weekday,
          ),
          candidateNoisyCount: 5,
          localContributingUsers: 1,
          dpApplied: true,
          epsilon: 0.44,
        ),
      ]);

      final json = matrix.toJson();
      expect(json['schemaVersion'], 'od-v1');
      expect(json['candidate'], true);
      expect(json['dpEpsilon'], 0.44);
      expect(json['kThreshold'], 100);
      final cells = json['cells'] as List;
      expect(cells, isA<List>());

      final cell = cells[0] as Map<String, Object?>;
      expect(cell['key'], 'OSM_1>OSM_2|8|weekday');
      expect(cell['candidateNoisyCount'], 5);
      expect(cell['dpApplied'], true);
      expect(cell['epsilon'], 0.44);

      // Verify the JSON is valid and can be re-encoded
      final encoded = jsonEncode(matrix.toJson());
      expect(encoded, isA<String>());
      expect(encoded, contains('OSM_1>OSM_2|8|weekday'));
    });
  });
}
