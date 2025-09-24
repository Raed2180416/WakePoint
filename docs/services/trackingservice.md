# TrackingService (lib/services/trackingservice.dart)

Purpose: Orchestrates background tracking, notifications, deviation/reroute, and transit-specific alarms.

Key responsibilities:
- Configure and run background service isolate (_onStart/_onStop)
- GPS stream management with power policy
- Deviation detection and route switching/reroute
- Destination, event, and pre-boarding alarms
- Journey progress notification updates

Sections below reference the current implementation.

## Public API
- initializeService(): sets up FlutterBackgroundService (Android/iOS configs)
- startTracking({destination, destinationName, alarmMode, alarmValue, allowNotificationsInTest, useInjectedPositions})
  - For tests: directly calls _onStart(TestServiceInstance(), params) and sets NotificationService.isTestMode
  - Shows journey progress notification (non-test)
- stopTracking(): stops alarms/vibration and tears down streams; cancels progress notification (non-test)
- Streams:
  - activeRouteStateStream: ActiveRouteManager state
  - routeSwitchStream: RouteSwitchEvent (emitted on manager switch and forced local switch)
  - rerouteDecisionStream: ReroutePolicy outcomes
- Test helpers: fusionActive, alarmTriggered, lastGpsUpdateValue, lastValidPosition

## Background Isolate State
- Subscriptions/timers: _positionSubscription, _gpsCheckTimer
- Movement/ETA gating: _startedAt, _startPosition, _distanceTravelledMeters, _etaSamples, _timeAlarmEligible, _smoothedETA
- Destination/alarm config: _destination, _destinationName, _alarmMode ('distance'|'time'|'stops'), _alarmValue (km|min|stops)
- Alarm flags: _destinationAlarmFired, _firedEventIndexes (event dedupe)
- Transit routing context: _transitMode, _routeEvents, _stepBoundsMeters, _stepStopsCumulative, _firstTransitBoarding, _preBoardingAlertFired
- Routing stack: _registry (RouteRegistry), _activeManager (ActiveRouteManager), _devMonitor, _reroutePolicy, _offlineCoordinator
- Speed/deviation: _lastSpeedMps, _lastActiveState

## Lifecycle
- _onStart(service, initialData?)
  - Listens for commands: startTracking, stopTracking, stopAlarm, useInjectedPositions, injectPosition
  - Parses params into state; resets gating/flags; shows initial progress (non-test)
  - Calls startLocationStream(service)
- _onStop()
  - Cancels streams/subs; stops fusion; stops alarm/vibration; cancels progress notification; logs

## GPS Stream and Power Policy
- startLocationStream(service)
  - Reads battery (non-test) and selects PowerPolicy
  - Applies gpsDropoutBuffer, reroutePolicy cooldown
  - Chooses stream: injected (_injectedCtrl) or Geolocator.getPositionStream(LocationSettings)
  - On each Position:
    - Updates timestamps and _lastProcessedPosition
    - Tracks movement for time-alarm gating (>=100m, >=3 ETA samples with speed >=0.5 m/s, >=30s)
    - Stops fusion if active
    - Computes naive ETA to destination (_smoothedETA)
    - Ingests raw position into ActiveRouteManager
    - Calls _checkAndTriggerAlarm(position, service)
    - service.invoke('updateLocation', {...})
  - Periodic timer (policy.notificationTick):
    - Enables SensorFusion after gpsDropoutBuffer of silence
    - Calls _updateNotification(service) to refresh journey progress
    - Re-evaluates time-alarm eligibility

## Route Registration
- registerRoute({key, mode, destinationName, points})
  - Upserts RouteEntry to RouteRegistry; initializes ActiveRouteManager/DeviationMonitor/ReroutePolicy/OfflineCoordinator
  - Bridges ActiveRouteManager:
    - stateStream: feeds DeviationMonitor with lateral offset computed against ACTIVE route via SnapToRoute; updates _lastActiveState; emits state
    - switchStream: forwards RouteSwitchEvent to _routeSwitchCtrl
  - DeviationMonitor stream:
    - Immediate test-only local switch for 100–150 m band when a candidate route improves offset by margin (20 m test / 50 m prod); emits RouteSwitchEvent
    - Sustained logic:
      - <100 m: ignore
      - 100–150 m: prefer local switch (avoid reroute)
      - >150 m: delegate to ReroutePolicy (subject to cooldown/online)
  - ReroutePolicy stream:
    - In test mode: emits decision without network
    - In prod: fetches new route via OfflineCoordinator.getRoute and registers via registerRouteFromDirections

- registerRouteFromDirections({directions, origin, destination, transitMode, destinationName})
  - Sets _transitMode and route key
  - Extracts points from simplified_polyline or overview_polyline; fallback to [origin, destination]
  - Builds step boundaries/stops via TransferUtils.buildStepBoundariesAndStops
  - Builds route events via TransferUtils.buildRouteEvents
  - Computes first transit boarding location:
    - Prefers transit_details.departure_stop.location for first TRANSIT step, else first point of step polyline
    - Stores in _firstTransitBoarding; resets _preBoardingAlertFired
  - Calls registerRoute(...)

## Alarm Logic: _checkAndTriggerAlarm()
- Destination alarms:
  - distance: trigger when straight-line distance to _destination <= alarmValue km
  - time: trigger when eligible and _smoothedETA <= alarmValue minutes
  - stops: compute remainingStops using _stepBoundsMeters/_stepStopsCumulative and registry progress; trigger when remainingStops <= alarmValue
- Event alarms (transfer/mode change):
  - Needs progressMeters (uses nearest RouteEntry.lastProgressMeters)
  - Applies alarm mode thresholds to distance/time/stops to the next event
  - Fires via NotificationService.showWakeUpAlarm with allowContinueTracking=true (does not stop service)
  - Deduplicates via _firedEventIndexes
- Metro pre-boarding alert (stops mode only):
  - If _transitMode and !_preBoardingAlertFired and _firstTransitBoarding != null
  - Compute distance from currentPosition to boarding; fire when <= 1000 m with title “Approaching metro station”
  - Records in tests via NotificationService test hooks; sets _preBoardingAlertFired
- When a destination alarm triggers:
  - Shows Wake Up! alarm (allowContinueTracking=false)
  - Invokes service.stopTracking to save battery

## Notifications
- _updateNotification(service)
  - If not in test: builds progress using most recent RouteEntry with progress data; shows remaining km and progress bar via NotificationService.showJourneyProgress
  - Fallback: straight-line remaining distance progress

## Test Mode Considerations
- startTracking(...) sets NotificationService.isTestMode based on allowNotificationsInTest flag
- Immediate switching in 100–150 m band to improve determinism in tests
- ReroutePolicy decisions emitted without network
- NotificationService records alarms to testRecordedAlarms
- Injected positions supported via service messages

## Key Nuances
- Deviation uses the active route snap lateral offset, not the last manager-reported offset, to avoid bias while switching
- Event alarms depend on progressMeters availability; nearest route by proximity (within 5 km) is used to read lastProgressMeters
- Time alarms guarded to avoid false positives when stationary
- Pre-boarding alert distance-only trigger (1 km) to ensure reliable behavior with synthetic directions lacking full geometry
