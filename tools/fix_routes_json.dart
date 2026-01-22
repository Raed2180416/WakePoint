import 'dart:convert';
import 'dart:io';

void main() async {
  final path =
      'd:/WakePoint/assets/ekf_test_routes/bengaluru_metro_routes.json';
  final file = File(path);
  if (!file.existsSync()) {
    print('Error: File not found');
    return;
  }

  final content = await file.readAsString();
  final data = jsonDecode(content) as Map<String, dynamic>;
  final routes = data['routes'] as List<dynamic>;

  // 1. Get source stations from 'majestic_to_nallur_halli'
  final sourceRoute = routes.firstWhere(
    (r) => r['id'] == 'majestic_to_nallur_halli',
  );
  final sourceStations =
      (sourceRoute['stations'] as List<dynamic>).cast<Map<String, dynamic>>();

  // 2. Reverse them to go Nallur Halli -> Majestic
  final reversedStations = sourceStations.reversed.toList();

  // 3. Find target route 'nallur_halli_to_vijayanagar'
  final targetRoute = routes.firstWhere(
    (r) => r['id'] == 'nallur_halli_to_vijayanagar',
  );

  // 4. Create new station list
  // Start with Nallur Halli (0.0km) implicitly from reversed list.
  // We need to adjust cumulative_meters if we want to be fancy, but for detection (lat/lng), it's fine.
  // The target route currently has [Nallur Halli, Vijayanagar].
  // We want [Nallur Halli, ..., Majestic, ..., Vijayanagar].
  // Since we don't have Majestic->Vijayanagar stations, we'll just append what we have.
  // Note: 'reversedStations' starts with Nallur Halli and ends with Majestic.

  // Remove the existing 'Nallur Halli' from reversed list if we keep the one in target?
  // Or just replace target's stations with (Reversed + Vijayanagar).

  // The current target stations:
  // 0: Nallur Halli (Lat 12.976591, Lng 77.725015)
  // 1: Vijayanagar (Lat 12.970734, Lng 77.537183)

  // The 'reversedStations' first element (Nallurhalli) from source might slightly differ in coord/name format?
  // Source: "Nallurhalli", lat 12.9765, lng 77.7252
  // Target: "Nallur Halli", lat 12.976591, lng 77.725015
  // Close enough. Let's use the source ones as they are known good for snaps?

  final newStations = <Map<String, dynamic>>[];
  newStations.addAll(reversedStations);

  // Inject missing stations between Majestic and Vijayanagar (Purple Line West)
  // 1. Krantivira Sangolli Rayanna (City Railway)
  newStations.add({
    "name": "Krantivira Sangolli Rayanna Railway Station",
    "recorded_name": "city railway station",
    "lat": 12.9758768,
    "lng": 77.5653767,
    "time_elapsed": 0.0, // TBD
    "cumulative_meters": 0.0, // TBD
  });

  // 2. Magadi Road
  newStations.add({
    "name": "Magadi Road",
    "recorded_name": "magadi road",
    "lat": 12.975632,
    "lng": 77.5553523,
    "time_elapsed": 0.0,
    "cumulative_meters": 0.0,
  });

  // 3. Hosahalli (Estimated/Interpolated)
  newStations.add({
    "name": "Hosahalli (Est)",
    "recorded_name": "hosahalli",
    "lat": 12.9738, // Approx
    "lng": 77.5455, // Approx
    "time_elapsed": 0.0,
    "cumulative_meters": 0.0,
  });

  // Add Vijayanagar at the end (from the original target route, if needed)
  final originalTargetStations = (targetRoute['stations'] as List<dynamic>);
  final vijayanagar = originalTargetStations.last; // The generic one

  newStations.add(vijayanagar as Map<String, dynamic>);

  print(
    'Injecting ${newStations.length} stations (including manual fixes) into nallur_halli_to_vijayanagar...',
  );

  targetRoute['stations'] = newStations;

  // Write back
  final encoder = JsonEncoder.withIndent('  ');
  await file.writeAsString(encoder.convert(data));
  print('Done.');
}
