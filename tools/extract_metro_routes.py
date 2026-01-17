#!/usr/bin/env python3
"""
Extract Metro Route Geometry from IMU recordings.
Maps recorded GPS + annotations to official station data.
"""

import csv
import json
from pathlib import Path
from dataclasses import dataclass, asdict
from typing import List, Tuple, Optional
import math

@dataclass
class Station:
    """Metro station with official and recorded data."""
    name: str                     # Official station name
    recorded_name: str            # Name from annotation
    lat: float                    # Latitude
    lng: float                    # Longitude
    time_elapsed: float           # Seconds from start
    cumulative_meters: float      # Distance along route

@dataclass
class MetroRoute:
    """Complete metro route with geometry and station data."""
    id: str
    name: str
    stations: List[Station]
    polyline_points: List[Tuple[float, float]]  # (lat, lng)
    cumulative_meters: List[float]              # Distance at each point
    total_meters: float
    duration_seconds: float

# Official Bengaluru Metro Purple Line stations (East-West)
# Ordered from Challaghatta (West) to Whitefield (East)
PURPLE_LINE_STATIONS = {
    # Western Extension
    'challaghatta': {'lat': 12.9657, 'lng': 77.4839, 'official': 'Challaghatta'},
    'kengeri_bus_terminal': {'lat': 12.9188, 'lng': 77.4865, 'official': 'Kengeri Bus Terminal'},
    'kengeri': {'lat': 12.9155, 'lng': 77.4836, 'official': 'Kengeri'},
    'pattanagere': {'lat': 12.9204, 'lng': 77.5038, 'official': 'Pattanagere'},
    'jnanabharathi': {'lat': 12.9348, 'lng': 77.5039, 'official': 'Jnanabharathi'},
    'rajarajeshwari_nagar': {'lat': 12.9272, 'lng': 77.5141, 'official': 'Rajarajeshwari Nagar'},
    'nayandahalli': {'lat': 12.9555, 'lng': 77.5220, 'official': 'Nayandahalli'},
    'mysore_road': {'lat': 12.9532, 'lng': 77.5398, 'official': 'Mysore Road'},
    'deepanjali_nagar': {'lat': 12.9604, 'lng': 77.5325, 'official': 'Deepanjali Nagar'},
    'attiguppe': {'lat': 12.9685, 'lng': 77.5378, 'official': 'Attiguppe'},
    'vijayanagar': {'lat': 12.9708, 'lng': 77.5374, 'official': 'Vijayanagar'},
    'hosahalli': {'lat': 12.9792, 'lng': 77.5404, 'official': 'Hosahalli'},
    'magadi_road': {'lat': 12.9822, 'lng': 77.5482, 'official': 'Magadi Road'},
    
    # Central (Majestic interchange)
    'ksr_railway_station': {'lat': 12.9757, 'lng': 77.5718, 'official': 'KSR Railway Station (Majestic)'},
    'majestic': {'lat': 12.9771, 'lng': 77.5711, 'official': 'Nadaprabhu Kempegowda (Majestic)'},
    
    # Eastern Section
    'central_college': {'lat': 12.9788, 'lng': 77.5793, 'official': 'Central College (Vidhana Soudha)'},
    'vidhana_soudha': {'lat': 12.9788, 'lng': 77.5793, 'official': 'Vidhana Soudha'},
    'dr_br_ambedkar': {'lat': 12.9795, 'lng': 77.5888, 'official': 'Dr. B.R. Ambedkar'},
    'sir_m_visvesvaraya': {'lat': 12.9782, 'lng': 77.5848, 'official': 'Sir M. Visvesvaraya'},
    'cubbon_park': {'lat': 12.9780, 'lng': 77.5915, 'official': 'Cubbon Park'},
    'mg_road': {'lat': 12.9756, 'lng': 77.6066, 'official': 'M.G. Road'},
    'trinity': {'lat': 12.9766, 'lng': 77.6183, 'official': 'Trinity'},
    'halasuru': {'lat': 12.9821, 'lng': 77.6211, 'official': 'Halasuru'},
    'indiranagar': {'lat': 12.9778, 'lng': 77.6408, 'official': 'Indiranagar'},
    'swami_vivekananda_road': {'lat': 12.9758, 'lng': 77.6585, 'official': 'Swami Vivekananda Road'},
    'sv_road': {'lat': 12.9758, 'lng': 77.6585, 'official': 'Swami Vivekananda Road'},
    'baiyappanahalli': {'lat': 12.9895, 'lng': 77.6674, 'official': 'Baiyappanahalli'},
    'benniganahalli': {'lat': 12.9902, 'lng': 77.6827, 'official': 'Benniganahalli'},
    'krishnarajapura': {'lat': 12.9899, 'lng': 77.6935, 'official': 'Krishnarajapura'},
    'kr': {'lat': 12.9899, 'lng': 77.6935, 'official': 'Krishnarajapura'},
    'singayyanapalya': {'lat': 12.9882, 'lng': 77.7060, 'official': 'Singayyanapalya'},
    'garudacharpalya': {'lat': 12.9850, 'lng': 77.7141, 'official': 'Garudacharpalya'},
    'hoodi': {'lat': 12.9838, 'lng': 77.7169, 'official': 'Hoodi Junction'},
    'seetharampalya': {'lat': 12.9808, 'lng': 77.7200, 'official': 'Seetharampalya'},
    'seetharam_palya': {'lat': 12.9808, 'lng': 77.7200, 'official': 'Seetharampalya'},
    'kundalahalli': {'lat': 12.9779, 'lng': 77.7230, 'official': 'Kundalahalli'},
    'nallurhalli': {'lat': 12.9765, 'lng': 77.7252, 'official': 'Nallurhalli'},
    'nallur_halli': {'lat': 12.9765, 'lng': 77.7252, 'official': 'Nallurhalli'},

    # Western terminus extension
    'rajajinagar': {'lat': 12.9998, 'lng': 77.5498, 'official': 'Rajajinagar'},
    'mahakavi_kuvempu': {'lat': 12.9938, 'lng': 77.5542, 'official': 'Mahakavi Kuvempu'},
    'srirampura': {'lat': 12.9897, 'lng': 77.5580, 'official': 'Srirampura'},
    'stirampura': {'lat': 12.9897, 'lng': 77.5580, 'official': 'Srirampura'},  # typo variant
    'mantri_square': {'lat': 12.9870, 'lng': 77.5665, 'official': 'Mantri Square Sampige Road'},
}

# Mapping from recorded annotation names to station keys
ANNOTATION_TO_STATION = {
    'rajajinagar': 'rajajinagar',
    'mahakavi kuvempu': 'mahakavi_kuvempu',
    'stirampura': 'srirampura',
    'srirampura': 'srirampura',
    'mantri square': 'mantri_square',
    'majestic': 'majestic',
    'krantiveera railway station': 'ksr_railway_station',
    'sir m': 'sir_m_visvesvaraya',
    'dr br': 'dr_br_ambedkar',
    'cubbon park': 'cubbon_park',
    'vidhana soudha': 'vidhana_soudha',
    'vidhan souda': 'vidhana_soudha',  # typo variant
    'central college': 'central_college',
    'mg road': 'mg_road',
    'trinity': 'trinity',
    'halasuru': 'halasuru',
    'indiranagar': 'indiranagar',
    'sv road': 'swami_vivekananda_road',
    'kv road': 'swami_vivekananda_road',  # typo variant
    'baiyappanahallo': 'baiyappanahalli',
    'baiyyapanahalli': 'baiyappanahalli',
    'baiyaopanahalli': 'baiyappanahalli',  # typo variant
    'swami vivekananda': 'swami_vivekananda_road',
    'benniganahalli': 'benniganahalli',
    'kr': 'krishnarajapura',
    'krishnarajapura': 'krishnarajapura',
    'singayyanapalya': 'singayyanapalya',
    'singayannapalaya': 'singayyanapalya',  # typo variant
    'garudacharpalya': 'garudacharpalya',
    'garudachar palya': 'garudacharpalya',
    'garydacharpalaya': 'garudacharpalya',  # typo variant
    'hoodi': 'hoodi',
    'seetharam palya': 'seetharampalya',
    'seetharampalya': 'seetharampalya',
    'seetharam palys': 'seetharampalya',
    'seetarama palaya': 'seetharampalya',  # typo variant
    'kundalahalli': 'kundalahalli',
    'nallur halli': 'nallurhalli',
    'nallurhalli': 'nallurhalli',
    'vijaynagar': 'vijayanagar',
    'vijayanagar': 'vijayanagar',
    'hosahalli': 'hosahalli',
    'magadi road': 'magadi_road',
}

def haversine_distance(lat1: float, lng1: float, lat2: float, lng2: float) -> float:
    """Calculate distance between two points in meters."""
    R = 6371000  # Earth radius in meters
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlambda = math.radians(lng2 - lng1)
    a = math.sin(dphi/2)**2 + math.cos(phi1)*math.cos(phi2)*math.sin(dlambda/2)**2
    return 2 * R * math.atan2(math.sqrt(a), math.sqrt(1-a))

def compute_cumulative_meters(points: List[Tuple[float, float]]) -> List[float]:
    """Compute cumulative distance along polyline."""
    cum = [0.0]
    for i in range(1, len(points)):
        d = haversine_distance(points[i-1][0], points[i-1][1], points[i][0], points[i][1])
        cum.append(cum[-1] + d)
    return cum

def extract_route_from_recording(folder_path: str, route_id: str, route_name: str) -> Optional[MetroRoute]:
    """Extract route data from IMU recording folder."""
    path = Path(folder_path)
    loc_file = path / 'Location.csv'
    annot_file = path / 'Annotation.csv'
    
    if not loc_file.exists() or not annot_file.exists():
        print(f"Missing files in {folder_path}")
        return None
    
    # Read annotations
    with open(annot_file, 'r') as f:
        annotations = list(csv.DictReader(f))
    
    # Read location data
    with open(loc_file, 'r') as f:
        locations = list(csv.DictReader(f))
    
    if not annotations or not locations:
        return None
    
    duration = float(locations[-1]['seconds_elapsed'])
    
    # Build station list with GPS positions
    stations = []
    for ann in annotations:
        recorded_name = ann['text'].strip().lower()
        time_elapsed = float(ann['seconds_elapsed'])
        
        # Skip non-station annotations
        if 'my annotation' in recorded_name:
            continue
        
        # Find matching official station
        station_key = ANNOTATION_TO_STATION.get(recorded_name)
        if not station_key or station_key not in PURPLE_LINE_STATIONS:
            print(f"  ⚠️ Unknown station: '{recorded_name}' -> {station_key}")
            continue
        
        official = PURPLE_LINE_STATIONS[station_key]
        
        # Find closest GPS position at annotation time
        closest_loc = min(locations, key=lambda x: abs(float(x['seconds_elapsed']) - time_elapsed))
        recorded_lat = float(closest_loc['latitude'])
        recorded_lng = float(closest_loc['longitude'])
        
        # Use official coordinates (more reliable than recorded GPS in tunnel)
        station = Station(
            name=official['official'],
            recorded_name=recorded_name,
            lat=official['lat'],
            lng=official['lng'],
            time_elapsed=time_elapsed,
            cumulative_meters=0  # Computed later
        )
        stations.append(station)
    
    if len(stations) < 2:
        print(f"  Not enough valid stations: {len(stations)}")
        return None
    
    # Build polyline from station positions
    polyline_points = [(s.lat, s.lng) for s in stations]
    cumulative_meters = compute_cumulative_meters(polyline_points)
    
    # Update station cumulative meters
    for i, s in enumerate(stations):
        s.cumulative_meters = cumulative_meters[i]
    
    return MetroRoute(
        id=route_id,
        name=route_name,
        stations=stations,
        polyline_points=polyline_points,
        cumulative_meters=cumulative_meters,
        total_meters=cumulative_meters[-1] if cumulative_meters else 0,
        duration_seconds=duration
    )

def main():
    base_path = Path(r'd:\WakePoint\GeoWake IMU  (File responses)')
    metro_path = base_path / 'Metro_Log_File'
    
    routes = []
    
    print("=" * 80)
    print("EXTRACTING METRO ROUTE GEOMETRY")
    print("=" * 80)
    
    # Route 1: Majestic -> Nallur Halli
    print("\n📍 Route 1: Majestic -> Nallur Halli")
    route1 = extract_route_from_recording(
        metro_path / 'Nadaprabhu_Kempegowda_Metro_Station_Majestic-2025-12-21_07-35-32',
        'majestic_to_nallur_halli',
        'Majestic to Nallur Halli (Purple Line East)'
    )
    if route1:
        print(f"  ✅ {len(route1.stations)} stations, {route1.total_meters:.0f}m, {route1.duration_seconds/60:.1f} min")
        for s in route1.stations:
            print(f"     - {s.name}: {s.cumulative_meters:.0f}m @ {s.time_elapsed:.0f}s")
        routes.append(route1)
    
    # Route 2: Rajajinagar -> Nallur Halli (full line)
    print("\n📍 Route 2: Rajajinagar -> Nallur Halli")
    route2 = extract_route_from_recording(
        metro_path / 'Rajajinagar_to_Nallur_Halli-2025-12-21_07-16-01_boom',
        'rajajinagar_to_nallur_halli',
        'Rajajinagar to Nallur Halli (Full Purple Line)'
    )
    if route2:
        print(f"  ✅ {len(route2.stations)} stations, {route2.total_meters:.0f}m, {route2.duration_seconds/60:.1f} min")
        routes.append(route2)
    
    # Route 3: Nallur Halli -> Vijayanagar (reverse direction)
    print("\n📍 Route 3: Nallur Halli -> Vijayanagar")
    route3 = extract_route_from_recording(
        metro_path / 'Nallur_Halli_to_Vijaynagar-2025-12-21_15-22-07',
        'nallur_halli_to_vijayanagar',
        'Nallur Halli to Vijayanagar (Purple Line West)'
    )
    if route3:
        print(f"  ✅ {len(route3.stations)} stations, {route3.total_meters:.0f}m, {route3.duration_seconds/60:.1f} min")
        routes.append(route3)
    
    # Save routes to JSON
    output_file = Path(r'd:\WakePoint\assets\ekf_test_routes\bengaluru_metro_routes.json')
    output_file.parent.mkdir(parents=True, exist_ok=True)
    
    output_data = {
        'version': 1,
        'generated': '2025-01-17',
        'source': 'IMU recordings + official station data',
        'routes': [asdict(r) for r in routes]
    }
    
    with open(output_file, 'w') as f:
        json.dump(output_data, f, indent=2)
    
    print(f"\n✅ Saved {len(routes)} routes to {output_file}")
    
    # Also generate Dart constants file
    dart_file = Path(r'd:\WakePoint\lib\core\ekf\test_routes.dart')
    with open(dart_file, 'w') as f:
        f.write('// Auto-generated: Bengaluru Metro test routes for EKF validation.\n')
        f.write('// Source: IMU recordings + official station coordinates.\n')
        f.write('// Generated: 2025-01-17\n\n')
        f.write("import 'package:google_maps_flutter/google_maps_flutter.dart';\n\n")
        
        for route in routes:
            var_name = route.id.upper()
            f.write(f'/// {route.name}\n')
            f.write(f'const List<LatLng> {var_name}_POLYLINE = [\n')
            for lat, lng in route.polyline_points:
                f.write(f'  LatLng({lat}, {lng}),\n')
            f.write('];\n\n')
            
            f.write(f'/// Station positions along {route.name}\n')
            f.write(f'const List<double> {var_name}_STATION_METERS = [\n')
            for s in route.stations:
                f.write(f'  {s.cumulative_meters:.1f}, // {s.name}\n')
            f.write('];\n\n')
            
            f.write(f'/// Station names for {route.name}\n')
            f.write(f'const List<String> {var_name}_STATION_NAMES = [\n')
            for s in route.stations:
                f.write(f"  '{s.name}',\n")
            f.write('];\n\n')
    
    print(f"✅ Generated Dart constants: {dart_file}")

if __name__ == '__main__':
    main()
