# TransferUtils (lib/services/transfer_utils.dart)

Purpose: Parses Directions-style steps to produce step cumulative distances/stops and event boundaries (transfers/mode changes).

- buildStepBoundariesAndStops(directions): { bounds: meters[], stops: cumulativeStops[] }
- buildRouteEvents(directions): RouteEventBoundary { type: 'transfer'|'change', meters, label? }[]
- Used by TrackingService for stops-mode and event alarms.
