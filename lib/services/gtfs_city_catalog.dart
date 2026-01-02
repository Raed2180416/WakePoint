import 'package:google_maps_flutter/google_maps_flutter.dart';

class GtfsCity {
  final String id;
  final String name;
  final double south;
  final double west;
  final double north;
  final double east;

  const GtfsCity({
    required this.id,
    required this.name,
    required this.south,
    required this.west,
    required this.north,
    required this.east,
  });

  bool contains(LatLng p) {
    return p.latitude >= south &&
        p.latitude <= north &&
        p.longitude >= west &&
        p.longitude <= east;
  }
}

class GtfsCityCatalog {
  /// Curated list of Indian metro cities.
  ///
  /// These bounds are intentionally broad and only used to choose which GTFS
  /// city-pack to download/cache.
  static const List<GtfsCity> cities = [
    // Bengaluru / Namma Metro
    GtfsCity(
      id: 'bengaluru',
      name: 'Bengaluru',
      south: 12.70,
      west: 77.30,
      north: 13.25,
      east: 77.90,
    ),
    // Delhi NCR / DMRC (Wide validation to catch Noida, Ghaziabad, Gurgaon, Faridabad)
    GtfsCity(
      id: 'delhi_ncr',
      name: 'Delhi NCR',
      south: 27.50,
      west: 76.00,
      north: 29.50,
      east: 78.50,
    ),
    // Mumbai (Wide to catch Navi Mumbai, Thane, extended MMR)
    GtfsCity(
      id: 'mumbai',
      name: 'Mumbai',
      south: 18.00,
      west: 72.00,
      north: 20.00,
      east: 74.00,
    ),
    // Chennai
    GtfsCity(
      id: 'chennai',
      name: 'Chennai',
      south: 12.80,
      west: 80.10,
      north: 13.30,
      east: 80.35,
    ),
    // Kolkata
    GtfsCity(
      id: 'kolkata',
      name: 'Kolkata',
      south: 22.40,
      west: 88.20,
      north: 22.75,
      east: 88.50,
    ),
    // Hyderabad
    GtfsCity(
      id: 'hyderabad',
      name: 'Hyderabad',
      south: 17.20,
      west: 78.20,
      north: 17.60,
      east: 78.70,
    ),
    // Kochi (Ernakulam district)
    GtfsCity(
      id: 'kochi',
      name: 'Kochi',
      south: 9.90,
      west: 76.20,
      north: 10.15,
      east: 76.45,
    ),
    // Lucknow
    GtfsCity(
      id: 'lucknow',
      name: 'Lucknow',
      south: 26.75,
      west: 80.80,
      north: 26.95,
      east: 81.05,
    ),
    // Jaipur
    GtfsCity(
      id: 'jaipur',
      name: 'Jaipur',
      south: 26.80,
      west: 75.70,
      north: 27.00,
      east: 75.90,
    ),
    // Nagpur
    GtfsCity(
      id: 'nagpur',
      name: 'Nagpur',
      south: 21.05,
      west: 79.00,
      north: 21.25,
      east: 79.20,
    ),
    // Pune
    GtfsCity(
      id: 'pune',
      name: 'Pune',
      south: 18.45,
      west: 73.75,
      north: 18.65,
      east: 73.95,
    ),
    // Ahmedabad
    GtfsCity(
      id: 'ahmedabad',
      name: 'Ahmedabad',
      south: 22.95,
      west: 72.50,
      north: 23.15,
      east: 72.70,
    ),
    // Navi Mumbai
    GtfsCity(
      id: 'navi_mumbai',
      name: 'Navi Mumbai',
      south: 18.90,
      west: 73.00,
      north: 19.15,
      east: 73.15,
    ),
    // Gurgaon (Rapid Metro)
    GtfsCity(
      id: 'gurgaon',
      name: 'Gurgaon',
      south: 28.42,
      west: 77.00,
      north: 28.52,
      east: 77.12,
    ),
  ];

  static String? resolveCityId(LatLng anchor) {
    for (final c in cities) {
      if (c.contains(anchor)) return c.id;
    }
    return null;
  }
}
