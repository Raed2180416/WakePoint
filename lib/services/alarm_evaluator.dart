import 'package:geowake2/core/logging/app_logger.dart';
import 'package:geowake2/services/transfer_utils.dart';

enum AlarmMode { stops, time, distance }

class AlarmEventType {
  static const String finalDestination = 'destination';
  static const String transfer = 'transfer';
  static const String modeChange = 'mode_change';
  static const String finalStation = 'final_station';
  static const String preBoarding = 'preBoarding';
}

class AlarmTrigger {
  final String eventType;
  final int? eventIndex;
  final int? legIndex; // Legacy compat
  final String? legId; // New ID-based tracker
  final String reason;
  final String message;
  final double? remainingStops;
  final double? remainingMeters;

  AlarmTrigger({
    required this.eventType,
    this.eventIndex,
    this.legIndex,
    this.legId,
    required this.reason,
    required this.message,
    this.remainingStops,
    this.remainingMeters,
  });
}

class AlarmEvaluator {
  // Constants can be kept or removed if unused.
  // _eventMetersTolerance was unused.
  // But new logic uses geometric checks.
  // I'll keep the class empty of legacy consts.

  /// CORE STATE MACHINE EVALUATOR
  ///
  /// This function enforces the "One Alarm Per Leg" rule strictly.
  /// It does not rely on "events" lists for triggering, but rather geometric progress.
  static AlarmTrigger? evaluateCoinciding({
    required AlarmMode mode,
    required double userValue, // N stops or N minutes
    required double progressMeters,
    required List<RouteEventBoundary>
    allEvents, // Kept for legacy/context if needed
    required Set<int> firedEventIndexes, // Legacy compat
    required Set<String> firedLegIds, // STRICT: One alarm per leg
    required bool isMetroLeg,
    required List<TransitLegStops> transitLegs,
    required int currentLegIndex,
    required bool isFinalLeg,
    List<double> stepBoundsMeters = const [],
    List<double> stepStopsCumulative = const [],
    List<int> stepDurationsSeconds = const [],
    double? currentSpeedMps,
    double legStartMeters = 0.0,
  }) {
    // ----------------------------------------------------------------------
    // FALLBACK: NO TRANSIT LEG CONTEXT
    // ----------------------------------------------------------------------
    // Some routes (or test fixtures) provide only route events + step bounds.
    // In that case we still must be able to fire the destination alarm
    // (including the "direct fire < 200m" behavior) without indexing into
    // `transitLegs`.
    if (transitLegs.isEmpty ||
        currentLegIndex < 0 ||
        currentLegIndex >= transitLegs.length) {
      final destEvents =
          allEvents
              .where((e) => e.type == AlarmEventType.finalDestination)
              .toList();
      if (destEvents.isEmpty) return null;

      final dest = destEvents.last;
      final remainingMeters = (dest.meters - progressMeters).toDouble();

      // Direct-fire rule: if destination is very close, fire immediately.
      if (remainingMeters <= 200.0) {
        return AlarmTrigger(
          eventType: AlarmEventType.finalDestination,
          reason: 'Direct Fire: destination < 200m',
          message: 'Arriving at Destination',
          remainingMeters: remainingMeters,
        );
      }

      // Final-leg 60% remaining rule (i.e. after 40% progress into the final leg).
      if (stepBoundsMeters.isNotEmpty) {
        final finalLegEnd = stepBoundsMeters.last;
        final finalLegStart =
            stepBoundsMeters.length >= 2
                ? stepBoundsMeters[stepBoundsMeters.length - 2]
                : 0.0;
        final finalLegLen = (finalLegEnd - finalLegStart).clamp(
          0.0,
          double.infinity,
        );
        final shouldFire =
            progressMeters >= (finalLegStart + finalLegLen * 0.4);
        if (shouldFire) {
          return AlarmTrigger(
            eventType: AlarmEventType.finalDestination,
            reason: 'Destination (60% remaining rule)',
            message: 'Arriving at Destination',
            remainingMeters: remainingMeters,
          );
        }
      }

      return null;
    }

    // ----------------------------------------------------------------------
    // OVERSHOOT HANDLING AT LEG BOUNDARIES
    // ----------------------------------------------------------------------
    // If progress jumps past the exact transfer boundary (end of previous leg)
    // into the next leg, we still want to fire the transfer alarm for the
    // *previous* metro leg when appropriate (prevents "missed" transfer alarms
    // when arriving exactly at the switch point).
    int evalLegIndex = currentLegIndex;
    bool evalIsFinalLeg = isFinalLeg;

    const double boundaryEpsilonMeters = 10.0;
    if (currentLegIndex > 0) {
      final prev = transitLegs[currentLegIndex - 1];
      final curr = transitLegs[currentLegIndex];

      final bool nearBoundary =
          progressMeters >= (prev.legEndMeters - boundaryEpsilonMeters) &&
          progressMeters <= (curr.legStartMeters + boundaryEpsilonMeters);

      if (nearBoundary && prev.isMetro && !firedLegIds.contains(prev.legId)) {
        evalLegIndex = currentLegIndex - 1;
        evalIsFinalLeg = false;
      }
    }

    // ----------------------------------------------------------------------
    // RULE 1: STRICT ONE ALARM PER LEG
    // ----------------------------------------------------------------------
    final leg = transitLegs[evalLegIndex];

    // DEBUG: Log leg ID check
    print(
      'LEG_CHECK: evalLegIdx=$evalLegIndex, legId=${leg.legId}, firedLegIds=$firedLegIds, contains=${firedLegIds.contains(leg.legId)}',
    );

    // ----------------------------------------------------------------------
    // RULE 1: STRICT ONE ALARM PER LEG
    // ----------------------------------------------------------------------
    if (firedLegIds.contains(leg.legId)) {
      print(
        'ALREADY_FIRED: legIdx=$evalLegIndex, legId=${leg.legId} is in firedLegIds=$firedLegIds, returning null',
      );
      alarmLog.warn(
        'ALARM_EVAL: Leg ${leg.legId} already fired, skipping.',
        data: {'firedLegIds': firedLegIds},
      );
      return null; // Already fired for this leg.
    }

    final legLength = leg.legEndMeters - leg.legStartMeters;
    final metersInLeg = (progressMeters - leg.legStartMeters).clamp(
      0.0,
      legLength,
    );

    // ----------------------------------------------------------------------
    // TIME MODE (ETA-BASED)
    // ----------------------------------------------------------------------
    // In time mode, alarms fire based on ETA to the current leg's target
    // (switch point for intermediate legs, destination for the final leg).
    if (mode == AlarmMode.time) {
      final thresholdSeconds = userValue * 60.0;
      if (thresholdSeconds <= 0) return null;

      // METRO JOURNEY TARGETING:
      // When a route contains metro legs, the user expectation for time-mode is
      // to warn N minutes before the meaningful "switchpoints":
      // - upcoming metro boarding (even if there's an intermediate bus/drive leg)
      // - metro line switchpoints (end of each metro leg)
      // - final destination (end of final leg)
      // This means: while on non-metro legs before the next metro leg, we
      // should compute ETA to the *next metro leg start* (boarding point), not
      // merely ETA to the current leg end.
      final bool isMetroJourney = transitLegs.any((l) => l.isMetro);

      // Interchange walk legs between metro legs are treated as metro context.
      // Never fire time-mode alarms on these legs (previous metro transfer alarm
      // covers the platform-change sequence).
      if (isMetroJourney && !evalIsFinalLeg && isMetroLeg && !leg.isMetro) {
        print(
          'TIME_MODE_SKIP: metro-context non-metro leg (idx=$evalLegIndex, legId=${leg.legId})',
        );
        return null;
      }

      // If we're on a non-metro leg in a metro journey (and not in metro context),
      // evaluate ETA to the next metro boarding point.
      if (isMetroJourney && !evalIsFinalLeg && !leg.isMetro && !isMetroLeg) {
        int? nextMetroIndex;
        for (int i = evalLegIndex + 1; i < transitLegs.length; i++) {
          if (transitLegs[i].isMetro) {
            nextMetroIndex = i;
            break;
          }
        }

        if (nextMetroIndex != null) {
          final nextMetroLeg = transitLegs[nextMetroIndex];
          final targetMeters = nextMetroLeg.legStartMeters;
          final preBoardingKey =
              'PreBoarding_toMetro_${nextMetroIndex}_${targetMeters.toStringAsFixed(0)}';

          // One preBoarding per boarding point, even across multiple preceding legs.
          if (firedLegIds.contains(preBoardingKey)) {
            print(
              'TIME_MODE_SKIP: preBoarding already fired for $preBoardingKey',
            );
            return null;
          }

          final remainingMeters = (targetMeters - progressMeters).clamp(
            0.0,
            double.infinity,
          );
          final etaSeconds = estimateEtaSecondsToMeters(
            progressMeters: progressMeters,
            targetMeters: targetMeters,
            stepBoundsMeters: stepBoundsMeters,
            stepDurationsSeconds: stepDurationsSeconds,
            currentSpeedMps: currentSpeedMps,
          );

          final shouldFire = etaSeconds <= thresholdSeconds;
          print(
            'TIME_ETA_DEBUG: legIdx=$evalLegIndex, isMetro=${leg.isMetro}, lineName=${leg.lineName}, '
            'target=nextMetroStart(idx=$nextMetroIndex, meters=${targetMeters.toStringAsFixed(0)}), '
            'progress=${progressMeters.toStringAsFixed(0)}, remainingM=${remainingMeters.toStringAsFixed(0)}, '
            'etaSec=${etaSeconds.toStringAsFixed(1)}, thresholdSec=${thresholdSeconds.toStringAsFixed(0)}, '
            'speedMps=${currentSpeedMps?.toStringAsFixed(2) ?? "null"}, shouldFire=$shouldFire, firedLegIds=$firedLegIds',
          );

          if (shouldFire) {
            // Prefer a transfer label at the upcoming boundary.
            const double boundaryLabelEpsilonMeters = 75.0;
            String? label;
            try {
              final candidates =
                  allEvents
                      .where(
                        (e) =>
                            e.type == AlarmEventType.transfer &&
                            (e.meters - targetMeters).abs() <=
                                boundaryLabelEpsilonMeters,
                      )
                      .toList();
              if (candidates.isNotEmpty) {
                candidates.sort(
                  (a, b) => (a.meters - targetMeters).abs().compareTo(
                    (b.meters - targetMeters).abs(),
                  ),
                );
                final raw = candidates.first.label;
                if (raw != null && raw.trim().isNotEmpty) {
                  label = raw.trim();
                }
              }
            } catch (_) {}

            final msg =
                label != null
                    ? 'Approaching metro station: $label'
                    : 'Approaching metro station';

            return AlarmTrigger(
              eventType: AlarmEventType.preBoarding,
              legIndex: nextMetroIndex,
              legId: preBoardingKey,
              reason:
                  'Time-mode preBoarding (ETA <= ${thresholdSeconds.toStringAsFixed(0)}s)',
              message: msg,
              remainingMeters: remainingMeters,
            );
          }

          // No preboarding yet.
          return null;
        }
      }

      final remainingMeters = (leg.legEndMeters - progressMeters).clamp(
        0.0,
        double.infinity,
      );

      // In metro journeys, the user-facing "switchpoint" is best represented
      // by the next boundary event from directions (transfer/mode change), not
      // strictly the extracted leg end meters. This matches what MapTracking
      // displays and prevents missing alarms when leg segmentation differs.
      double switchTargetMeters = leg.legEndMeters;
      if (isMetroJourney && !evalIsFinalLeg) {
        try {
          final candidates =
              allEvents
                  .where(
                    (e) =>
                        (e.type == AlarmEventType.transfer ||
                            e.type == AlarmEventType.modeChange ||
                            e.type == AlarmEventType.finalStation) &&
                        e.meters > progressMeters,
                  )
                  .toList();
          if (candidates.isNotEmpty) {
            candidates.sort((a, b) => a.meters.compareTo(b.meters));
            final next = candidates.first;

            // Only trust this as the leg's switch target if it is close to this
            // leg's end (or within the leg). This avoids picking a boundary far
            // ahead belonging to a later leg.
            const double targetEpsilonMeters = 250.0;
            final bool withinOrNearEnd =
                (next.meters >= leg.legStartMeters - targetEpsilonMeters) &&
                (next.meters <= leg.legEndMeters + targetEpsilonMeters);

            if (withinOrNearEnd) {
              switchTargetMeters = next.meters;
            }
          }
        } catch (_) {}
      }

      // Prefer speed-based ETA when speed is credible (supports simulated
      // speed multipliers). Fall back to step-duration estimate when speed is
      // missing/low to avoid optimistic ETAs when stationary.
      final etaSeconds = estimateEtaSecondsToMeters(
        progressMeters: progressMeters,
        targetMeters: switchTargetMeters,
        stepBoundsMeters: stepBoundsMeters,
        stepDurationsSeconds: stepDurationsSeconds,
        currentSpeedMps: currentSpeedMps,
      );
      final shouldFire = etaSeconds <= thresholdSeconds;

      // DEBUG: Log ETA calculation details
      print(
        'TIME_ETA_DEBUG: legIdx=$evalLegIndex, isMetro=${leg.isMetro}, lineName=${leg.lineName}, '
        'legStart=${leg.legStartMeters.toStringAsFixed(0)}, '
        'legEnd=${leg.legEndMeters.toStringAsFixed(0)}, target=${switchTargetMeters.toStringAsFixed(0)}, progress=${progressMeters.toStringAsFixed(0)}, '
        'remainingM=${remainingMeters.toStringAsFixed(0)}, etaSec=${etaSeconds.toStringAsFixed(1)}, '
        'thresholdSec=${thresholdSeconds.toStringAsFixed(0)}, speedMps=${currentSpeedMps?.toStringAsFixed(2) ?? "null"}, '
        'stepBounds=${stepBoundsMeters.length}, stepDurations=${stepDurationsSeconds.length}, '
        'shouldFire=$shouldFire, firedLegIds=$firedLegIds',
      );
      // Extra debug: Show first few step bounds if available
      if (stepBoundsMeters.isNotEmpty) {
        final boundsPreview = stepBoundsMeters
            .take(10)
            .map((b) => b.toStringAsFixed(0))
            .join(', ');
        final durPreview = stepDurationsSeconds
            .take(10)
            .map((d) => d.toString())
            .join(', ');
        print(
          'TIME_ETA_STEPS: bounds=[$boundsPreview${stepBoundsMeters.length > 10 ? "..." : ""}], '
          'durs=[$durPreview${stepDurationsSeconds.length > 10 ? "..." : ""}]',
        );
      }

      if (shouldFire) {
        if (evalIsFinalLeg) {
          return AlarmTrigger(
            eventType: AlarmEventType.finalDestination,
            legIndex: evalLegIndex,
            legId: leg.legId,
            reason:
                'Time-mode destination (ETA <= ${thresholdSeconds.toStringAsFixed(0)}s)',
            message: 'Arriving at Destination',
            remainingMeters: remainingMeters,
          );
        }

        // If we're on a non-metro leg approaching a metro leg, treat as preBoarding.
        // IMPORTANT: If we're currently in a "metro context" (on a metro leg OR
        // in an interchange walk between metro legs), do NOT emit a preBoarding
        // alarm. The preceding metro leg's transfer alarm already covers the
        // platform-change sequence, and emitting "Prepare to board" here causes
        // duplicate/stacked alarms at transfer stations.
        if (!isMetroLeg &&
            !leg.isMetro &&
            evalLegIndex + 1 < transitLegs.length) {
          final nextLeg = transitLegs[evalLegIndex + 1];
          if (nextLeg.isMetro) {
            final targetMeters = nextLeg.legStartMeters;
            final preBoardingKey =
                'PreBoarding_toMetro_${evalLegIndex + 1}_${targetMeters.toStringAsFixed(0)}';

            // If we already warned for this boarding point (e.g., earlier on a
            // longer driving/bus leg), do not re-warn on the short final walk.
            if (firedLegIds.contains(preBoardingKey)) {
              print(
                'TIME_MODE_SKIP: duplicate preBoarding for $preBoardingKey',
              );
              return null;
            }

            // Prefer a transfer label at the upcoming boundary for raw fixtures.
            const double boundaryLabelEpsilonMeters = 75.0;
            String? label;
            try {
              final candidates =
                  allEvents
                      .where(
                        (e) =>
                            e.type == AlarmEventType.transfer &&
                            (e.meters - leg.legEndMeters).abs() <=
                                boundaryLabelEpsilonMeters,
                      )
                      .toList();
              if (candidates.isNotEmpty) {
                candidates.sort(
                  (a, b) => (a.meters - leg.legEndMeters).abs().compareTo(
                    (b.meters - leg.legEndMeters).abs(),
                  ),
                );
                final raw = candidates.first.label;
                if (raw != null && raw.trim().isNotEmpty) {
                  label = raw.trim();
                }
              }
            } catch (_) {}

            final msg =
                label != null
                    ? 'Approaching metro station: $label'
                    : 'Approaching metro station';

            return AlarmTrigger(
              eventType: AlarmEventType.preBoarding,
              legIndex: evalLegIndex + 1,
              legId: preBoardingKey,
              reason:
                  'Time-mode preBoarding (ETA <= ${thresholdSeconds.toStringAsFixed(0)}s)',
              message: msg,
              remainingMeters: (targetMeters - progressMeters).clamp(
                0.0,
                double.infinity,
              ),
            );
          }
        }

        // NOTE: Do NOT suppress metro->non-metro on the metro leg itself.
        // Users still want an N-minute prior warning before leaving the metro.
        // We suppress only the *immediate* post-metro connector leg below.

        // Also suppress the *immediate* mode-change alarm on the short egress
        // walk right after the final metro leg (metro exit → pickup/drive).
        // These are usually very short connector legs, and the user has
        // already mentally switched modes when leaving the metro.
        if (isMetroJourney &&
            !leg.isMetro &&
            evalLegIndex > 0 &&
            transitLegs[evalLegIndex - 1].isMetro) {
          final bool anyMetroAhead = transitLegs
              .sublist(evalLegIndex)
              .any((l) => l.isMetro);
          final bool isPostLastMetro = !anyMetroAhead;
          final bool isShortConnector = legLength <= 600.0;
          if (isPostLastMetro && isShortConnector) {
            print(
              'TIME_MODE_SKIP: suppress post-metro connector change at legIdx=$evalLegIndex (len=${legLength.toStringAsFixed(0)}m)',
            );
            return null;
          }
        }

        // Otherwise, treat as an upcoming change/transfer depending on context.
        const double boundaryLabelEpsilonMeters = 75.0;
        RouteEventBoundary? boundaryEvent;
        try {
          boundaryEvent = allEvents.firstWhere(
            (e) =>
                (e.type == AlarmEventType.transfer ||
                    e.type == AlarmEventType.modeChange ||
                    e.type == AlarmEventType.finalStation) &&
                e.associatedLegIndex == evalLegIndex,
            orElse: () => RouteEventBoundary(meters: -1, type: 'none'),
          );
          if (boundaryEvent.type == 'none') boundaryEvent = null;
        } catch (_) {
          boundaryEvent = null;
        }
        if (boundaryEvent == null) {
          final candidates =
              allEvents
                  .where(
                    (e) =>
                        (e.type == AlarmEventType.transfer ||
                            e.type == AlarmEventType.modeChange ||
                            e.type == AlarmEventType.finalStation) &&
                        (e.meters - leg.legEndMeters).abs() <=
                            boundaryLabelEpsilonMeters,
                  )
                  .toList();
          if (candidates.isNotEmpty) {
            candidates.sort(
              (a, b) => (a.meters - leg.legEndMeters).abs().compareTo(
                (b.meters - leg.legEndMeters).abs(),
              ),
            );
            boundaryEvent = candidates.first;
          }
        }

        String type = AlarmEventType.transfer;
        if (boundaryEvent?.type == AlarmEventType.finalStation) {
          type = AlarmEventType.finalStation;
        } else if (boundaryEvent?.type == AlarmEventType.modeChange) {
          type = AlarmEventType.modeChange;
        } else if (boundaryEvent?.type == AlarmEventType.transfer) {
          type = AlarmEventType.transfer;
        } else if (evalLegIndex + 1 < transitLegs.length) {
          final nextLeg = transitLegs[evalLegIndex + 1];
          if (!nextLeg.isMetro) type = AlarmEventType.modeChange;
        }

        final rawLabel = boundaryEvent?.label;
        final label =
            (rawLabel != null && rawLabel.trim().isNotEmpty)
                ? rawLabel.trim()
                : null;

        final String prefix =
            type == AlarmEventType.transfer
                ? 'Transfer Ahead'
                : 'Upcoming change';
        final String baseMessage = label != null ? '$prefix: $label' : prefix;

        // If destination is extremely close after this boundary, prefer destination.
        final RouteEventBoundary? dest =
            allEvents
                    .where((e) => e.type == AlarmEventType.finalDestination)
                    .isNotEmpty
                ? allEvents
                    .where((e) => e.type == AlarmEventType.finalDestination)
                    .last
                : null;
        if (dest != null) {
          final postLegMeters = (dest.meters - leg.legEndMeters).toDouble();
          if (postLegMeters >= 0 && postLegMeters <= 300.0) {
            final remainingToDest = (dest.meters - progressMeters).toDouble();
            return AlarmTrigger(
              eventType: AlarmEventType.finalDestination,
              legIndex: evalLegIndex,
              legId: leg.legId,
              reason:
                  'Time-mode: destination beats switch (<=300m after boundary)',
              message: 'Arriving at Destination',
              remainingMeters: remainingToDest,
            );
          }
        }

        return AlarmTrigger(
          eventType: type,
          legIndex: evalLegIndex,
          legId: leg.legId,
          reason:
              'Time-mode switch (ETA <= ${thresholdSeconds.toStringAsFixed(0)}s)',
          message: baseMessage,
          remainingMeters: remainingMeters,
        );
      }

      // DEBUG: Log when time mode does NOT fire
      print(
        'TIME_MODE_NO_FIRE: legIdx=$evalLegIndex, legId=${leg.legId}, '
        'etaSec=${etaSeconds.toStringAsFixed(1)}, threshold=${thresholdSeconds.toStringAsFixed(0)}, '
        'shouldFire was false (ETA > threshold)',
      );
      return null;
    }

    // ----------------------------------------------------------------------
    // RULE 2: MODE-SPECIFIC LOGIC
    // ----------------------------------------------------------------------

    if (leg.isMetro) {
      // METRO LOGIC (N stops before next switchpoint)
      //
      // Goal: fire exactly when there are N stops remaining until this leg's end station.
      // We model "stops remaining" as including the target station as 1 remaining.
      //
      // IMPORTANT: `TransitLegStops.stopMeters` is treated as the list of
      // INTERMEDIATE stop boundaries (length == numStops), excluding endpoints.
      // This keeps behavior consistent across OSM-enhanced and estimated legs.

      final thresholdN = userValue.toInt();

      // Defensive: enforce "intermediate-only" semantics by stripping endpoints.
      // Some older fixtures may still include leg start/end meters.
      final rawStopMeters = leg.stopMeters.toSet().toList()..sort();
      final dedupedStopMeters =
          rawStopMeters
              .where(
                (sm) =>
                    sm > leg.legStartMeters + 1.0 &&
                    sm < leg.legEndMeters - 1.0,
              )
              .toList();

      // DEBUG: Log raw and deduped stop meters for diagnosis
      alarmLog.debug('''
╔════════════════════════════════════════════════════════════════
    ║ ALARM_EVAL DEBUG - Metro Leg $evalLegIndex ($leg.lineName)
╠════════════════════════════════════════════════════════════════
║ progressMeters      : ${progressMeters.toStringAsFixed(1)}m
║ legStartMeters      : ${leg.legStartMeters.toStringAsFixed(1)}m
║ legEndMeters        : ${leg.legEndMeters.toStringAsFixed(1)}m
║ legLength           : ${legLength.toStringAsFixed(1)}m
║ isActualPositions   : ${leg.isActualPositions}
║ numStops (leg)      : ${leg.numStops}
║ rawStopMeters       : $rawStopMeters
║ dedupedStopMeters   : $dedupedStopMeters
║ stopNames           : ${leg.stopNames.take(5)}${leg.stopNames.length > 5 ? '...' : ''}
╚════════════════════════════════════════════════════════════════''');

      // EDGE CASE: Metro leg with NO intermediate stops
      // If dedupedStopMeters is empty, this means we have only:
      // - The boarding point (leg start / switchpoint)
      // - The alighting point (leg end / next switchpoint/destination)
      // In this case, remainingStops = 1 (the target station).
      //
      // IMPORTANT: With 0 intermediate stops, the max alarm threshold the user
      // could have set is 1 stop. "1 stop prior" means the switchpoint itself
      // (the metro station right before the final stop of this leg).
      //
      // Instead of firing IMMEDIATELY, we use the 60% DISTANCE rule:
      // Fire when 40% of the leg is completed (60% remaining to switchpoint).
      // This gives the user time to prepare before arriving at the switchpoint.
      if (dedupedStopMeters.isEmpty) {
        alarmLog.warn(
          'ALARM_EVAL: Metro leg with ZERO intermediate stops - using 60% distance rule',
        );

        // Apply 60% rule: fire when 40% of leg is completed
        final thresholdMeters = legLength * 0.4;
        final shouldFire = thresholdN >= 1 && metersInLeg >= thresholdMeters;

        alarmLog.debug('''
╠════════════════════════════════════════════════════════════════
║ ZERO-INTERMEDIATE-STOPS CASE (60% distance rule):
║   legLength              : ${legLength.toStringAsFixed(1)}m
║   metersInLeg            : ${metersInLeg.toStringAsFixed(1)}m
║   40% threshold          : ${thresholdMeters.toStringAsFixed(1)}m
║   thresholdN (user)      : $thresholdN
║   shouldFire             : $shouldFire
╚════════════════════════════════════════════════════════════════''');

        if (shouldFire) {
          // Determine boundary label/type for messaging.
          const double boundaryLabelEpsilonMeters = 75.0;
          RouteEventBoundary? boundaryEvent;
          try {
            boundaryEvent = allEvents.firstWhere(
              (e) =>
                  (e.type == AlarmEventType.transfer ||
                      e.type == AlarmEventType.modeChange ||
                      e.type == AlarmEventType.finalStation) &&
                  e.associatedLegIndex == evalLegIndex,
              orElse: () => RouteEventBoundary(meters: -1, type: 'none'),
            );
            if (boundaryEvent.type == 'none') boundaryEvent = null;
          } catch (_) {
            boundaryEvent = null;
          }
          if (boundaryEvent == null) {
            final candidates =
                allEvents
                    .where(
                      (e) =>
                          (e.type == AlarmEventType.transfer ||
                              e.type == AlarmEventType.modeChange ||
                              e.type == AlarmEventType.finalStation) &&
                          (e.meters - leg.legEndMeters).abs() <=
                              boundaryLabelEpsilonMeters,
                    )
                    .toList();
            if (candidates.isNotEmpty) {
              candidates.sort(
                (a, b) => (a.meters - leg.legEndMeters).abs().compareTo(
                  (b.meters - leg.legEndMeters).abs(),
                ),
              );
              boundaryEvent = candidates.first;
            }
          }

          // Destination proximity override (final leg check)
          if (evalIsFinalLeg) {
            return AlarmTrigger(
              eventType: AlarmEventType.finalDestination,
              legIndex: evalLegIndex,
              legId: leg.legId,
              reason:
                  'Metro Final Destination (0 intermediate stops - 60% rule)',
              message: 'Arriving at Destination (1 stop)',
              remainingStops: 1.0,
              remainingMeters: legLength - metersInLeg,
            );
          }

          String type = AlarmEventType.transfer;
          if (boundaryEvent?.type == AlarmEventType.finalStation) {
            type = AlarmEventType.finalStation;
          } else if (boundaryEvent?.type == AlarmEventType.modeChange) {
            type = AlarmEventType.modeChange;
          } else if (evalLegIndex + 1 < transitLegs.length) {
            final nextLeg = transitLegs[evalLegIndex + 1];
            if (!nextLeg.isMetro) type = AlarmEventType.modeChange;
          }

          final rawLabel = boundaryEvent?.label;
          final label =
              (rawLabel != null && rawLabel.trim().isNotEmpty)
                  ? rawLabel.trim()
                  : null;
          final String prefix =
              type == AlarmEventType.transfer
                  ? 'Transfer Ahead'
                  : 'Upcoming change';
          final String baseMessage = label != null ? '$prefix: $label' : prefix;

          return AlarmTrigger(
            eventType: type,
            legIndex: evalLegIndex,
            legId: leg.legId,
            reason: 'Metro Transfer (0 intermediate stops - 60% rule)',
            message: '$baseMessage (1 stop)',
            remainingStops: 1.0,
            remainingMeters: legLength - metersInLeg,
          );
        }

        return null;
      }

      // Count how many intermediate stop boundaries have been reached/passed.
      int passedIntermediate = 0;
      for (final sm in dedupedStopMeters) {
        if (progressMeters >= sm) {
          passedIntermediate++;
        } else {
          break;
        }
      }

      // Remaining stations until destination includes the destination station itself.
      final remainingIntermediate =
          dedupedStopMeters.length - passedIntermediate;
      final remainingStopsToTarget = remainingIntermediate + 1;

      // Edge case: legs with no intermediate stations (board -> target next).
      // In this case, remainingStopsToTarget will be 1, and N=1 should fire immediately.
      final bool shouldFire =
          thresholdN <= 0 ? false : (remainingStopsToTarget <= thresholdN);

      // ============ DEBUG LOGGING ============
      alarmLog.debug('''
╔══════════════════════════════════════════════════════════════
║ ALARM_EVAL DEBUG - Metro Leg $currentLegIndex ($leg.lineName)
╠══════════════════════════════════════════════════════════════
║ progressMeters      : ${progressMeters.toStringAsFixed(1)}m
║ legStartMeters      : ${leg.legStartMeters.toStringAsFixed(1)}m
║ legEndMeters        : ${leg.legEndMeters.toStringAsFixed(1)}m
║ isActualPositions   : ${leg.isActualPositions}
║ numStops (leg)      : ${leg.numStops}
║ dedupedStopMeters   : $dedupedStopMeters
║ passedIntermediate  : $passedIntermediate
║ remainingIntermediate: $remainingIntermediate
║ thresholdN (user)   : $thresholdN
║ remainingStopsToTarget: $remainingStopsToTarget
║ shouldFire          : $shouldFire
╚══════════════════════════════════════════════════════════════''');

      if (shouldFire) {
        // DETERMINE TYPE
        // Priority Rule: Final Destination > Switch
        // If this is the Final Route Leg, it is Destination.
        if (evalIsFinalLeg) {
          return AlarmTrigger(
            eventType: AlarmEventType.finalDestination,
            legIndex: evalLegIndex,
            legId: leg.legId,
            reason: "Metro Final Destination ($thresholdN stops prior)",
            message:
                "Arriving at Destination (${remainingStopsToTarget} stop${remainingStopsToTarget == 1 ? '' : 's'})",
            remainingStops: remainingStopsToTarget.toDouble(),
          );
        } else {
          // Determine if Transfer vs Mode Change based on NEXT leg.
          // NOTE: Triggering remains purely geometric; we only use events here
          // to enrich the *message* (labels like station/transfer point) and
          // to distinguish explicit 'final_station' boundaries.
          const double boundaryLabelEpsilonMeters = 75.0;
          RouteEventBoundary? boundaryEvent;

          // Prefer an explicitly associated event for this leg.
          try {
            boundaryEvent = allEvents.firstWhere(
              (e) =>
                  (e.type == AlarmEventType.transfer ||
                      e.type == AlarmEventType.modeChange ||
                      e.type == AlarmEventType.finalStation) &&
                  e.associatedLegIndex == evalLegIndex,
              orElse: () => RouteEventBoundary(meters: -1, type: 'none'),
            );
            if (boundaryEvent.type == 'none') boundaryEvent = null;
          } catch (_) {
            boundaryEvent = null;
          }

          // Fall back to a meters-nearby boundary event at the leg end.
          if (boundaryEvent == null) {
            final candidates =
                allEvents
                    .where(
                      (e) =>
                          (e.type == AlarmEventType.transfer ||
                              e.type == AlarmEventType.modeChange ||
                              e.type == AlarmEventType.finalStation) &&
                          (e.meters - leg.legEndMeters).abs() <=
                              boundaryLabelEpsilonMeters,
                    )
                    .toList();
            if (candidates.isNotEmpty) {
              candidates.sort(
                (a, b) => (a.meters - leg.legEndMeters).abs().compareTo(
                  (b.meters - leg.legEndMeters).abs(),
                ),
              );
              boundaryEvent = candidates.first;
            }
          }

          // Destination proximity override: if destination is extremely close
          // after this boundary, prefer the destination alarm.
          final RouteEventBoundary? dest =
              allEvents
                      .where((e) => e.type == AlarmEventType.finalDestination)
                      .isNotEmpty
                  ? allEvents
                      .where((e) => e.type == AlarmEventType.finalDestination)
                      .last
                  : null;
          if (dest != null) {
            final postLegMeters = (dest.meters - leg.legEndMeters).toDouble();
            if (postLegMeters >= 0 && postLegMeters <= 300.0) {
              final remainingToDest = (dest.meters - progressMeters).toDouble();
              return AlarmTrigger(
                eventType: AlarmEventType.finalDestination,
                legIndex: evalLegIndex,
                legId: leg.legId,
                reason: 'Destination beats switch (<=300m after boundary)',
                message: 'Arriving at Destination',
                remainingStops: remainingStopsToTarget.toDouble(),
                remainingMeters: remainingToDest,
              );
            }
          }

          // Default type based on next leg.
          String type = AlarmEventType.transfer;
          if (boundaryEvent?.type == AlarmEventType.finalStation) {
            type = AlarmEventType.finalStation;
          } else if (boundaryEvent?.type == AlarmEventType.modeChange) {
            type = AlarmEventType.modeChange;
          } else if (boundaryEvent?.type == AlarmEventType.transfer) {
            type = AlarmEventType.transfer;
          } else if (evalLegIndex + 1 < transitLegs.length) {
            final nextLeg = transitLegs[evalLegIndex + 1];
            if (!nextLeg.isMetro) {
              type = AlarmEventType.modeChange;
            }
          }

          final rawLabel = boundaryEvent?.label;
          final label =
              (rawLabel != null && rawLabel.trim().isNotEmpty)
                  ? rawLabel.trim()
                  : null;

          final String prefix =
              type == AlarmEventType.transfer
                  ? 'Transfer Ahead'
                  : 'Upcoming change';
          final String baseMessage = label != null ? '$prefix: $label' : prefix;

          return AlarmTrigger(
            eventType: type,
            legIndex: evalLegIndex,
            legId: leg.legId,
            reason: "Metro Transfer ($thresholdN stops prior)",
            message:
                "$baseMessage (${remainingStopsToTarget} stop${remainingStopsToTarget == 1 ? '' : 's'})",
            remainingStops: remainingStopsToTarget.toDouble(),
          );
        }
      }
    } else {
      // NON-METRO LOGIC (60% Rule)
      // Walk/Drive/Bus

      // Check if previous leg was metro (this is a transfer FROM metro)
      final previousLegWasMetro =
          currentLegIndex > 0 &&
          currentLegIndex - 1 < transitLegs.length &&
          transitLegs[currentLegIndex - 1].isMetro;

      // Check if next leg is metro (this is a transfer TO metro)
      final nextLegIsMetro =
          currentLegIndex + 1 < transitLegs.length &&
          transitLegs[currentLegIndex + 1].isMetro;

      // Check if ANY previous leg was metro (to determine if we're in first driven portion)
      final anyPreviousMetro = transitLegs
          .take(currentLegIndex)
          .any((l) => l.isMetro);

      // Find the first metro leg (if any) to determine driven portion end
      final firstMetroLeg = transitLegs.cast<TransitLegStops?>().firstWhere(
        (l) => l != null && l.isMetro,
        orElse: () => null,
      );

      // Check if we're in the DRIVEN PORTION before the first metro
      // This is true if:
      // 1. There IS a metro on this route
      // 2. We haven't passed any metro yet
      // 3. Our current progress is before the first metro
      final bool isInDrivenPortionBeforeFirstMetro =
          firstMetroLeg != null &&
          !anyPreviousMetro &&
          progressMeters < firstMetroLeg.legStartMeters;

      // PREBOARDING THRESHOLD CALCULATION:
      // - For legs in the driven portion before FIRST metro: Fire at 40% of cumulative driven portion
      // - For other non-metro legs: Fire at 40% of current leg
      double thresholdMeters;
      double progressForThreshold;
      String thresholdReason;
      String preboardingLegId; // Stable ID for the entire driven portion

      if (isInDrivenPortionBeforeFirstMetro) {
        final drivenPortionEnd = firstMetroLeg.legStartMeters;

        // Fire at 40% of the TOTAL driven portion (not just current leg)
        thresholdMeters = drivenPortionEnd * 0.4;
        progressForThreshold = progressMeters;
        thresholdReason =
            "40% of driven portion (${drivenPortionEnd.toStringAsFixed(0)}m total)";

        // Use a STABLE leg ID for the entire driven portion so it fires only once
        preboardingLegId =
            'Preboarding_0_${drivenPortionEnd.toStringAsFixed(0)}';

        // EARLY EXIT: Check if this preboarding has already fired
        if (firedLegIds.contains(preboardingLegId)) {
          return null; // Already fired preboarding for this driven portion
        }

        alarmLog.debug('''
      🚌 PREBOARDING THRESHOLD (First Metro Driven Portion):
         Driven portion end: ${drivenPortionEnd.toStringAsFixed(0)}m
         40% threshold: ${thresholdMeters.toStringAsFixed(0)}m
         Current progress: ${progressMeters.toStringAsFixed(0)}m
         Stable preboarding ID: $preboardingLegId''');
      } else {
        // Standard 40% of current leg threshold
        thresholdMeters = legLength * 0.4;
        progressForThreshold = metersInLeg;
        thresholdReason = "40% of leg (${legLength.toStringAsFixed(0)}m)";
        preboardingLegId = leg.legId; // Use current leg's ID
      }

      // Rule: Fire when 60% of the leg/portion is LEFT (i.e., after 40% progress).
      final shouldFire = progressForThreshold >= thresholdMeters;

      if (shouldFire) {
        // DEBUG LEG ID PERSISTENCE
        alarmLog.debug('''
      🔍 NON-METRO FIRE CHECK:
         LegID: ${leg.legId}
         Preboarding ID: $preboardingLegId
         Fired? ${firedLegIds.contains(preboardingLegId)}
         All Fired: $firedLegIds
         Threshold Reason: $thresholdReason''');

        // EARLY EXIT: Already fired this preboarding
        if (firedLegIds.contains(preboardingLegId)) {
          alarmLog.debug('   ⏭️ Already fired, skipping');
          return null;
        }

        if (isFinalLeg) {
          // Rule: Final Destination on Walk/Drive
          // Only verified because we ARE on the final leg (checked by caller/state).

          // FIX: In Distance Mode, we strictly honor the N km threshold calculated
          // in AlarmController. We intentionally suppress this progress-based
          // (60% rule) alarm to avoid "phantom" alarms mid-route.
          if (mode == AlarmMode.distance) {
            return null;
          }

          return AlarmTrigger(
            eventType: AlarmEventType.finalDestination,
            legIndex: currentLegIndex,
            legId: leg.legId,
            reason: "Walking Destination (60% rule)",
            message: "Arriving at Destination",
            remainingMeters: legLength - metersInLeg,
          );
        } else {
          // Check if this is a short transfer walk between metros (skip preboarding)
          // Transfer walks at interchange stations are typically < 500m
          final isShortLeg = legLength < 500;

          // IMPORTANT: Preboarding should only exist when we're actually
          // approaching a metro boarding point on the route polyline.
          // Allow preboarding if:
          // 1. Next leg is metro directly, OR
          // 2. We're in the driven portion before the first metro
          if (!nextLegIsMetro && !isInDrivenPortionBeforeFirstMetro) {
            return null;
          }

          // Skip preboarding for short metro-to-metro transfer walks
          // The previous metro leg's switch alarm already warned the user
          if (isShortLeg && previousLegWasMetro && nextLegIsMetro) {
            alarmLog.debug(
              'ALARM_EVAL: Skipping preboarding for short transfer walk (${legLength.toStringAsFixed(0)}m) between metros',
            );
            return null; // Don't fire redundant alarm
          }

          // Intermediate Walk -> Next Leg (Preboarding)
          // Keep a stable prefix for tests and UX.
          String message = 'Approaching metro station';

          // For preboarding in driven portion, use first metro leg info
          // For direct next-metro scenario, use next leg info
          final targetMetroLeg =
              isInDrivenPortionBeforeFirstMetro
                  ? firstMetroLeg
                  : (nextLegIsMetro && currentLegIndex + 1 < transitLegs.length
                      ? transitLegs[currentLegIndex + 1]
                      : null);

          if (targetMetroLeg != null) {
            // Prefer the metro leg's first stop name (polyline/route-derived),
            // then fall back to the explicit preBoarding event label, then line name.
            String? stationName;
            if (targetMetroLeg.stopNames.isNotEmpty) {
              stationName = targetMetroLeg.stopNames.first.trim();
              if (stationName.isEmpty) stationName = null;
            }

            String? boardingLabel;
            // Find the metro leg's index to look up preBoarding event
            final targetMetroIndex = transitLegs.indexOf(targetMetroLeg);
            try {
              final ev = allEvents.firstWhere(
                (e) =>
                    e.type == AlarmEventType.preBoarding &&
                    e.associatedLegIndex == targetMetroIndex,
                orElse: () => RouteEventBoundary(meters: -1, type: 'none'),
              );
              if (ev.type == AlarmEventType.preBoarding) {
                boardingLabel = ev.label;
              }
            } catch (_) {
              boardingLabel = null;
            }

            // Raw/test fixtures often express the boarding station as a `transfer`
            // event at the boundary (without an explicit preBoarding event).
            if (boardingLabel == null || boardingLabel.trim().isEmpty) {
              const double boundaryLabelEpsilonMeters = 75.0;
              try {
                final candidates =
                    allEvents
                        .where(
                          (e) =>
                              e.type == AlarmEventType.transfer &&
                              (e.meters - targetMetroLeg.legStartMeters)
                                      .abs() <=
                                  boundaryLabelEpsilonMeters,
                        )
                        .toList();
                if (candidates.isNotEmpty) {
                  candidates.sort(
                    (a, b) => (a.meters - targetMetroLeg.legStartMeters)
                        .abs()
                        .compareTo(
                          (b.meters - targetMetroLeg.legStartMeters).abs(),
                        ),
                  );
                  final raw = candidates.first.label;
                  if (raw != null && raw.trim().isNotEmpty) {
                    boardingLabel = raw.trim();
                  }
                }
              } catch (_) {}
            }

            final boarding = boardingLabel;
            if (boarding != null && boarding.trim().isNotEmpty) {
              message = 'Approaching metro station: ${boarding.trim()}';
            } else if (stationName != null) {
              message = 'Approaching metro station: $stationName';
            } else {
              final lineName = targetMetroLeg.lineName;
              if (lineName != null && lineName.trim().isNotEmpty) {
                message = 'Approaching metro station: ${lineName.trim()}';
              }
            }
          }

          // Calculate remaining meters to first metro
          final remainingToMetro =
              isInDrivenPortionBeforeFirstMetro
                  ? (firstMetroLeg.legStartMeters - progressMeters)
                  : legLength - metersInLeg;

          return AlarmTrigger(
            eventType: AlarmEventType.preBoarding,
            legIndex: currentLegIndex,
            legId: preboardingLegId, // Use stable preboarding ID
            reason:
                isInDrivenPortionBeforeFirstMetro
                    ? "Pre-boarding (40% of driven portion)"
                    : "Pre-boarding (60% remaining rule)",
            message: message,
            remainingMeters: remainingToMetro,
          );
        }
      }
    }

    return null;
  }

  /// Estimate ETA (seconds) from the current progress (meters along route) to a
  /// target meter position in the same domain.
  ///
  /// - If [currentSpeedMps] is credible (> 0.5 m/s), uses distance/speed.
  ///   This preserves simulation behavior where speed is intentionally scaled.
  /// - Otherwise, if step bounds + durations are available, estimates remaining
  ///   time using step durations proportionally.
  /// - Final fallback uses a conservative walking-speed model.
  static double estimateEtaSecondsToMeters({
    required double progressMeters,
    required double targetMeters,
    required List<double> stepBoundsMeters,
    required List<int> stepDurationsSeconds,
    double? currentSpeedMps,
  }) {
    final remainingMeters = (targetMeters - progressMeters).clamp(
      0.0,
      double.infinity,
    );
    if (remainingMeters <= 0) {
      print('ETA_CALC: remainingMeters<=0, returning 0');
      return 0.0;
    }

    double? speedEta;
    final v = currentSpeedMps ?? 0.0;
    if (v.isFinite && v > 0.5) {
      speedEta = remainingMeters / v;
    }

    double? stepEta;
    if (stepBoundsMeters.isNotEmpty &&
        stepBoundsMeters.length == stepDurationsSeconds.length) {
      final totalMeters = stepBoundsMeters.last;

      // If the step-domain does not cover the current progress/target meters
      // domain (e.g., polyline-domain progress meters are larger), step-based
      // ETA can incorrectly clamp and return 0, causing immediate/ghost alarms.
      // Detect mismatch and fall back to conservative ETA instead.
      const double domainMismatchEpsilonMeters = 50.0;
      final bool domainMismatch =
          (targetMeters - totalMeters) > domainMismatchEpsilonMeters ||
          (progressMeters - totalMeters) > domainMismatchEpsilonMeters;
      if (domainMismatch) {
        print(
          'ETA_CALC: step-domain mismatch. progress=$progressMeters, target=$targetMeters, stepTotal=$totalMeters. Ignoring steps.',
        );
      } else {
        // Clamp target into the step-domain.
        final clampedTarget = targetMeters.clamp(0.0, totalMeters);
        final clampedProgress = progressMeters.clamp(0.0, totalMeters);

        print(
          'ETA_CALC_DETAIL: targetMeters=$targetMeters, totalMeters=$totalMeters, '
          'clampedTarget=$clampedTarget, clampedProgress=$clampedProgress',
        );

        if (clampedTarget <= clampedProgress) {
          print(
            'ETA_CALC: step-based clamp produced target<=progress. '
            'progress=$progressMeters, target=$targetMeters, stepTotal=$totalMeters. Falling back.',
          );
          // Fall through to conservative fallback below.
        } else {
          int stepIdxAt(double meters) {
            for (int i = 0; i < stepBoundsMeters.length; i++) {
              if (meters <= stepBoundsMeters[i]) return i;
            }
            return stepBoundsMeters.length - 1;
          }

          final startIdx = stepIdxAt(clampedProgress);
          final endIdx = stepIdxAt(clampedTarget);

          print(
            'ETA_CALC_STEPS: startIdx=$startIdx (bound=${startIdx < stepBoundsMeters.length ? stepBoundsMeters[startIdx].toStringAsFixed(0) : "N/A"}), '
            'endIdx=$endIdx (bound=${endIdx < stepBoundsMeters.length ? stepBoundsMeters[endIdx].toStringAsFixed(0) : "N/A"})',
          );

          double prevBound(int idx) =>
              idx == 0 ? 0.0 : stepBoundsMeters[idx - 1];

          double partialStepSeconds({
            required int idx,
            required double fromMeters,
            required double toMeters,
          }) {
            final start = prevBound(idx);
            final end = stepBoundsMeters[idx];
            final len = (end - start);
            if (!(len.isFinite) || len <= 0) return 0.0;

            final from = fromMeters.clamp(start, end);
            final to = toMeters.clamp(start, end);
            final metersIn = (to - from).clamp(0.0, len);
            final frac = metersIn / len;
            final dur = stepDurationsSeconds[idx].toDouble().clamp(0.0, 1e9);
            return dur * frac;
          }

          double eta = 0.0;
          if (startIdx == endIdx) {
            eta += partialStepSeconds(
              idx: startIdx,
              fromMeters: clampedProgress,
              toMeters: clampedTarget,
            );
          } else {
            eta += partialStepSeconds(
              idx: startIdx,
              fromMeters: clampedProgress,
              toMeters: stepBoundsMeters[startIdx],
            );
            for (int i = startIdx + 1; i < endIdx; i++) {
              eta += stepDurationsSeconds[i].toDouble().clamp(0.0, 1e9);
            }
            eta += partialStepSeconds(
              idx: endIdx,
              fromMeters: prevBound(endIdx),
              toMeters: clampedTarget,
            );
          }

          if (eta.isFinite && eta >= 0) {
            print(
              'ETA_CALC: step-based. startIdx=$startIdx, endIdx=$endIdx, eta=$eta',
            );
            stepEta = eta;
          }
        }
      }
    }

    // Hybrid selection:
    // - We *want* to avoid optimistic early alarms from speed spikes.
    // - But always picking the larger (stepEta) can become far too pessimistic
    //   when simulation speed is intentionally scaled up (step durations are
    //   still “real-world” durations).
    //
    // Strategy:
    // 1) Add a small safety buffer to speed ETA.
    // 2) Allow step-based ETA to override only when it's reasonably close.
    // 3) Cap how much stepEta can inflate the estimate.
    if (speedEta != null && stepEta != null) {
      const double speedSafetyFactor = 1.20; // dampen speed spikes
      const double maxStepInflationVsSpeed = 1.50; // cap pessimism

      final speedEtaBuffered = speedEta * speedSafetyFactor;
      final stepCap = speedEtaBuffered * maxStepInflationVsSpeed;
      final chosen =
          (stepEta <= speedEtaBuffered)
              ? speedEtaBuffered
              : (stepEta <= stepCap ? stepEta : stepCap);

      print(
        'ETA_CALC: hybrid. speedEta=${speedEta.toStringAsFixed(1)}, '
        'speedEtaBuffered=${speedEtaBuffered.toStringAsFixed(1)}, '
        'stepEta=${stepEta.toStringAsFixed(1)}, stepCap=${stepCap.toStringAsFixed(1)}, '
        'chosen=${chosen.toStringAsFixed(1)}',
      );
      return chosen;
    }

    if (stepEta != null) {
      return stepEta;
    }

    if (speedEta != null) {
      const double speedSafetyFactor = 1.20;
      final eta = speedEta * speedSafetyFactor;
      print(
        'ETA_CALC: speed-based. speed=$v, remaining=$remainingMeters, eta=$eta',
      );
      return eta;
    }

    // Conservative default when speed and step durations aren't usable.
    const double fallbackMps = 1.4;
    final fallbackEta = remainingMeters / fallbackMps;
    print(
      'ETA_CALC: fallback (no steps/speed). remaining=$remainingMeters, eta=$fallbackEta',
    );
    return fallbackEta;
  }
}
