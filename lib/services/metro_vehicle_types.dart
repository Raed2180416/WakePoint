/// Single source of truth for the Google Directions API
/// `transit_details.line.vehicle.type` values that GeoWake treats as
/// "metro / rapid rail" for alarm-tracking and reroute-validation purposes.
///
/// Historically two predicates disagreed:
///   * `TransferUtils._isMetroTransitStep` accepted SUBWAY, HEAVY_RAIL, RAIL,
///     METRO_RAIL, MONORAIL, TRAM, COMMUTER_TRAIN.
///   * `RerouteConstraints._routeHasMetroLeg` accepted only the first five,
///     so a valid alternate running on TRAM / COMMUTER_TRAIN was rejected and
///     tracking was terminated on reroute.
///
/// Both predicates now test membership of THIS set so they cannot drift apart.
/// LIGHT_RAIL is included as well — some Indian metro systems surface as
/// LIGHT_RAIL in the Directions payload.
///
/// Values are UPPER-CASE; callers upper-case the raw API string before testing.
library;

const Set<String> kMetroVehicleTypes = <String>{
  'SUBWAY',
  'HEAVY_RAIL',
  'RAIL',
  'METRO_RAIL',
  'MONORAIL',
  'TRAM',
  'COMMUTER_TRAIN',
  'LIGHT_RAIL',
};
