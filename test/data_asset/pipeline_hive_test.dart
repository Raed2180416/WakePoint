import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:geowake2/services/data_asset/aggregate_egress_sink.dart';
import 'package:geowake2/services/data_asset/aggregate_schema.dart';
import 'package:geowake2/services/data_asset/contribution_cap.dart';
import 'package:geowake2/services/data_asset/data_asset_config.dart';
import 'package:geowake2/services/data_asset/data_asset_pipeline.dart';
import 'package:geowake2/services/data_asset/mobility_consent_service.dart';
import 'package:geowake2/services/data_asset/od_aggregator.dart';
import 'package:geowake2/services/data_asset/od_cell.dart';
import 'package:geowake2/services/data_asset/station_binner.dart';

/// Aggregator whose recordTrip always throws — proves the pipeline is fail-open.
class _ThrowingAggregator extends OdAggregator {
  @override
  Future<void> recordTrip({
    required TripEndpoint origin,
    required TripEndpoint destination,
    required String localDate,
  }) async {
    throw StateError('boom');
  }
}

({
  Future<String?> Function(String) load,
  Future<void> Function(String, String) save,
}) memStore() {
  final m = <String, String>{};
  return (load: (k) async => m[k], save: (k, v) async => m[k] = v);
}

// Two catalogue stations far enough apart to be distinct O-D endpoints.
StationBinner testBinner() => StationBinner.fromEntries([
      (id: 'S_A', lat: 12.9716, lng: 77.5946),
      (id: 'S_B', lat: 12.9352, lng: 77.6245),
    ]);

const mondayEpochMs = 1704096600000; // 2024-01-01T08:30:00Z
const istOffset = 330;

void main() {
  late Directory dir;
  var boxSeq = 0;

  setUpAll(() {
    dir = Directory.systemTemp.createTempSync('gw_data_asset_test');
    Hive.init(dir.path);
  });

  tearDownAll(() async {
    await Hive.close();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<OdAggregator> freshAggregator() async {
    final n = boxSeq++;
    final odBox = await Hive.openBox<int>('od_$n');
    final arrivalBox = await Hive.openBox<int>('arr_$n');
    final erasureBox = await Hive.openBox<String>('era_$n');
    final capBox = await Hive.openBox<String>('cap_$n');
    return OdAggregator(
      cap: ContributionCap(box: capBox),
      odBox: odBox,
      arrivalBox: arrivalBox,
      erasureBox: erasureBox,
    );
  }

  group('bright line / egress tripwires', () {
    test('egress is compile-time OFF', () {
      expect(kDataAssetEgressEnabled, isFalse);
    });

    test('the only wired sink after init is NullEgressSink', () async {
      final store = memStore();
      final pipe = DataAssetPipeline.instance;
      await pipe.init(
        consent: MobilityConsentService(load: store.load, save: store.save),
        aggregator: await freshAggregator(),
        binner: testBinner(),
      );
      expect(pipe.wiredSink, isA<NullEgressSink>());
    });

    test('NullEgressSink.upload transmits nothing (no throw, no return value)',
        () async {
      const sink = NullEgressSink();
      // The signature accepts ONLY an OdFlowMatrix of ReleasedCell.
      await sink.upload(const OdFlowMatrixHolder().empty());
    });
  });

  group('pipeline OFF (default consent)', () {
    test('onTripCompleted with consent OFF makes ZERO writes', () async {
      final store = memStore();
      final agg = await freshAggregator();
      final pipe = DataAssetPipeline.instance;
      await pipe.init(
        consent: MobilityConsentService(load: store.load, save: store.save),
        aggregator: agg,
        binner: testBinner(),
      );
      await pipe.onTripCompleted(
        originLat: 12.9716,
        originLng: 77.5946,
        destLat: 12.9352,
        destLng: 77.6245,
        epochMs: mondayEpochMs,
        tzOffsetMinutes: istOffset,
      );
      final snap = await agg.snapshot();
      expect(snap, isEmpty);
    });
  });

  group('pipeline ON', () {
    test('records one capped O-D count and builds a candidate', () async {
      final store = memStore();
      final consent =
          MobilityConsentService(load: store.load, save: store.save);
      final agg = await freshAggregator();
      final pipe = DataAssetPipeline.instance;
      await pipe.init(consent: consent, aggregator: agg, binner: testBinner());
      await consent.grant();

      // Fire the same trip twice in the same local day.
      for (var i = 0; i < 2; i++) {
        await pipe.onTripCompleted(
          originLat: 12.9716,
          originLng: 77.5946,
          destLat: 12.9352,
          destLng: 77.6245,
          epochMs: mondayEpochMs,
          tzOffsetMinutes: istOffset,
        );
      }
      final snap = await agg.snapshot();
      expect(snap.length, 1);
      // Per-cell/day cap = 1: two fires still yield count 1.
      expect(snap.single.count, 1);
      expect(snap.single.key.originStationId, 'S_A');
      expect(snap.single.key.destStationId, 'S_B');

      // buildReleaseCandidate runs end-to-end; single-device users≈1 so k-anon
      // suppresses everything (candidate is empty but the pipeline completed).
      final candidate = await pipe.buildReleaseCandidate();
      expect(candidate.cells, isEmpty);
    });

    test('contribution cap allows at most 4 distinct cells/day', () async {
      final store = memStore();
      final consent =
          MobilityConsentService(load: store.load, save: store.save);
      final cap = ContributionCap(box: await Hive.openBox<String>('cap_x'));
      var reserved = 0;
      for (var i = 0; i < 10; i++) {
        final ok = await cap.tryReserve(
          OdCellKey(
            originStationId: 'O$i',
            destStationId: 'D$i',
            hourBin: 8,
            dayType: DayType.weekday,
          ),
          localDate: '2024-01-01',
        );
        if (ok) reserved++;
      }
      expect(reserved, kPerUserMaxCellsPerDay); // 4
      await consent.load();
    });

    test('contribution cap rolls over to a new local day', () async {
      final cap = ContributionCap(box: await Hive.openBox<String>('cap_roll'));
      final key = const OdCellKey(
        originStationId: 'O',
        destStationId: 'D',
        hourBin: 8,
        dayType: DayType.weekday,
      );
      expect(await cap.tryReserve(key, localDate: '2024-01-01'), isTrue);
      expect(await cap.tryReserve(key, localDate: '2024-01-01'), isFalse);
      // New day -> reservable again (old day pruned).
      expect(await cap.tryReserve(key, localDate: '2024-01-02'), isTrue);
    });
  });

  group('fail-open', () {
    test('a throwing aggregator never throws out of onTripCompleted', () async {
      final store = memStore();
      final consent =
          MobilityConsentService(load: store.load, save: store.save);
      final pipe = DataAssetPipeline.instance;
      await pipe.init(
        consent: consent,
        aggregator: _ThrowingAggregator(),
        binner: testBinner(),
      );
      await consent.grant();
      // Must complete normally despite recordTrip throwing.
      await pipe.onTripCompleted(
        originLat: 12.9716,
        originLng: 77.5946,
        destLat: 12.9352,
        destLng: 77.6245,
        epochMs: mondayEpochMs,
        tzOffsetMinutes: istOffset,
      );
    });
  });

  group('withdrawal erases + logs', () {
    test('withdraw wipes counts and appends an erasure record', () async {
      final store = memStore();
      final consent =
          MobilityConsentService(load: store.load, save: store.save);
      final agg = await freshAggregator();
      final pipe = DataAssetPipeline.instance;
      await pipe.init(consent: consent, aggregator: agg, binner: testBinner());
      await consent.grant();
      await pipe.onTripCompleted(
        originLat: 12.9716,
        originLng: 77.5946,
        destLat: 12.9352,
        destLng: 77.6245,
        epochMs: mondayEpochMs,
        tzOffsetMinutes: istOffset,
      );
      expect((await agg.snapshot()), isNotEmpty);

      await consent.withdraw();
      expect(await agg.snapshot(), isEmpty);
      expect(await agg.erasureLogLength(), greaterThanOrEqualTo(1));
      expect(consent.isSharingEnabled, isFalse);
    });
  });
}

/// Small helper to build an empty OdFlowMatrix without exposing ReleasedCell
/// construction to the test (ReleasedCell is merge-backend-only).
class OdFlowMatrixHolder {
  const OdFlowMatrixHolder();
  OdFlowMatrix empty() => const OdFlowMatrix(cells: []);
}
