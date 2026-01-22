import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/core/ekf/station_association.dart';

void main() {
  group('StationAssociation', () {
    test('selects single candidate within margin window', () {
      final assoc = StationAssociation();
      final result = assoc.selectCandidate(
        stationMeters: const [100.0, 200.0, 300.0],
        sEst: 205.0,
        sigmaS: 10.0,
        isMetroLeg: true,
        zuptConfirmed: true,
        zuptDwell: const Duration(seconds: 25),
      );

      expect(result, isNotNull);
      expect(result!.stationIndex, 1);
    });

    test('rejects when multiple candidates in window', () {
      final assoc = StationAssociation();
      final result = assoc.selectCandidate(
        stationMeters: const [100.0, 200.0, 210.0],
        sEst: 205.0,
        sigmaS: 10.0,
        isMetroLeg: true,
        zuptConfirmed: true,
        zuptDwell: const Duration(seconds: 25),
      );

      expect(result, isNull);
    });

    test('rejects when not metro leg', () {
      final assoc = StationAssociation();
      final result = assoc.selectCandidate(
        stationMeters: const [100.0, 200.0],
        sEst: 100.0,
        sigmaS: 5.0,
        isMetroLeg: false,
        zuptConfirmed: true,
        zuptDwell: const Duration(seconds: 25),
      );

      expect(result, isNull);
    });

    test('rejects when ZUPT dwell not met', () {
      final assoc = StationAssociation();
      final result = assoc.selectCandidate(
        stationMeters: const [100.0],
        sEst: 100.0,
        sigmaS: 5.0,
        isMetroLeg: true,
        zuptConfirmed: true,
        zuptDwell: const Duration(seconds: 2),  // Less than 3s default
      );

      expect(result, isNull);
    });
    
    group('adaptive margin (window overlap fix)', () {
      test('config calculates adaptive margin correctly', () {
        const config = StationAssociationConfig();
        
        // At sigmaS=10: margin = 50 + 0.5*10 = 55m
        expect(config.marginForSigma(10.0), closeTo(55.0, 0.1));
        
        // At sigmaS=50: margin = 50 + 0.5*50 = 75m
        expect(config.marginForSigma(50.0), closeTo(75.0, 0.1));
        
        // At sigmaS=100: margin = 50 + 0.5*100 = 100m
        expect(config.marginForSigma(100.0), closeTo(100.0, 0.1));
        
        // At sigmaS=300: margin capped at maxMarginMeters=150
        expect(config.marginForSigma(300.0), closeTo(150.0, 0.1));
      });
      
      test('adaptive margin prevents overlap with close stations at low sigma', () {
        final assoc = StationAssociation();
        
        // Two stations 150m apart, sigmaS=10m
        // Window = 3*10 + 55 = 85m - stations should not overlap
        final result = assoc.selectCandidate(
          stationMeters: const [100.0, 250.0],  // 150m apart
          sEst: 105.0,  // Near first station
          sigmaS: 10.0,
          isMetroLeg: true,
          zuptConfirmed: true,
          zuptDwell: const Duration(seconds: 25),
        );
        
        expect(result, isNotNull);
        expect(result!.stationIndex, 0);  // Should select first station only
      });
      
      test('adaptive margin allows wider window with high sigma for single candidate', () {
        final assoc = StationAssociation();
        
        // Stations 300m apart, sigmaS=50m
        // Window = 3*50 + 75 = 225m - wide enough to capture station
        final result = assoc.selectCandidate(
          stationMeters: const [0.0, 300.0, 600.0],
          sEst: 280.0,  // 20m from station at 300m, 280m from station at 0
          sigmaS: 50.0,  // Higher uncertainty
          isMetroLeg: true,
          zuptConfirmed: true,
          zuptDwell: const Duration(seconds: 25),
        );
        
        expect(result, isNotNull);
        expect(result!.stationIndex, 1);  // Should select station at 300m
      });
      
      test('rejects multiple candidates even with adaptive margin', () {
        final assoc = StationAssociation();
        
        // Stations 120m apart, sigmaS=30m
        // Window = 3*30 + 65 = 155m
        // Both stations within window if sEst is between them
        final result = assoc.selectCandidate(
          stationMeters: const [100.0, 220.0],  // 120m apart
          sEst: 160.0,  // Exactly between them
          sigmaS: 30.0,
          isMetroLeg: true,
          zuptConfirmed: true,
          zuptDwell: const Duration(seconds: 25),
        );
        
        // Both are within 155m window, should reject
        expect(result, isNull);
        expect(assoc.lastDiagnostics?.rejectReason, contains('MULTIPLE'));
      });
      
      test('margin caps at maxMarginMeters for very high sigma', () {
        final assoc = StationAssociation();
        
        // sigmaS=200m would give margin = 50 + 0.5*200 = 150m (capped)
        // Window = 3*200 + 150 = 750m
        const config = StationAssociationConfig();
        expect(config.marginForSigma(200.0), equals(150.0));
        
        // Verify selection still works with capped margin
        final result = assoc.selectCandidate(
          stationMeters: const [0.0, 1000.0, 2000.0],  // Very far apart
          sEst: 950.0,  // Near 1000m station
          sigmaS: 200.0,
          isMetroLeg: true,
          zuptConfirmed: true,
          zuptDwell: const Duration(seconds: 25),
        );
        
        expect(result, isNotNull);
        expect(result!.stationIndex, 1);
      });
    });
    
    group('diagnostics', () {
      test('diagnostics include window size and candidates', () {
        final assoc = StationAssociation();
        
        assoc.selectCandidate(
          stationMeters: const [100.0, 200.0],
          sEst: 150.0,
          sigmaS: 20.0,
          isMetroLeg: true,
          zuptConfirmed: true,
          zuptDwell: const Duration(seconds: 25),
        );
        
        final diag = assoc.lastDiagnostics;
        expect(diag, isNotNull);
        expect(diag!.sEst, equals(150.0));
        expect(diag.sigmaS, equals(20.0));
        expect(diag.numCandidates, equals(2));
        expect(diag.candidateIndices, containsAll([0, 1]));
      });
      
      test('diagnostics show rejection reason', () {
        final assoc = StationAssociation();
        
        assoc.selectCandidate(
          stationMeters: const [100.0],
          sEst: 500.0,  // Far from any station
          sigmaS: 5.0,  // Small window
          isMetroLeg: true,
          zuptConfirmed: true,
          zuptDwell: const Duration(seconds: 25),
        );
        
        final diag = assoc.lastDiagnostics;
        expect(diag?.rejectReason, contains('NO_CANDIDATES'));
      });
    });
  });
}
