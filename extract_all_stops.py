import json
import os
import sys

# Flush output
sys.stdout.reconfigure(encoding='utf-8')

CITY_MAPPINGS = {
    'ahmedabad': ['Gujarat Metro', 'Ahmedabad'],
    'bengaluru': ['Namma Metro', 'Bangalore Metro'],
    'chennai': ['Chennai Metro'],
    'delhi_ncr': ['Delhi Metro', 'Noida Metro', 'National Capital Region Transport Corporation', 'Rapid Metro Gurgaon'],
    'gurgaon': ['Rapid Metro Gurgaon'],
    'hyderabad': ['Hyderabad Metro'],
    'jaipur': ['Jaipur Metro'],
    'kochi': ['Kochi Metro'],
    'kolkata': ['Kolkata Metro'],
    'lucknow': ['Lucknow Metro'],
    'mumbai': ['Mumbai Metro', 'MMRDA', 'Mumbai Metro One'],
    'nagpur': ['Nagpur Metro', 'MahaMetro'],
    'noida': ['Noida Metro'],
    'navi_mumbai': ['Navi Mumbai Metro', 'CIDCO'],
    'pune': ['Pune Metro'],
    'kanpur': ['Kanpur Metro', 'Uttar Pradesh Metro Rail Corporation'],
    'agra': ['Agra Metro'],
    'indore': ['Indore Metro', 'Madhya Pradesh Metro Rail Corporation'],
    'bhopal': ['Bhopal Metro'],
}

# Coarse city bounding boxes to reduce misclassification when OSM tags are sparse.
# Format: (south, west, north, east)
CITY_BBOX_FALLBACKS = {
    'noida': (28.45, 77.25, 28.75, 77.55),
    'delhi_ncr': (28.40, 76.80, 28.90, 77.50),
    'bengaluru': (12.75, 77.35, 13.20, 77.85),
    'chennai': (12.80, 80.05, 13.25, 80.35),
    'mumbai': (18.85, 72.75, 19.35, 73.10),
    'kolkata': (22.40, 88.20, 22.75, 88.50),
    'hyderabad': (17.20, 78.25, 17.60, 78.65),
    'ahmedabad': (22.85, 72.45, 23.15, 72.75),
    'kochi': (9.85, 76.15, 10.10, 76.40),
    'jaipur': (26.80, 75.65, 27.05, 75.95),
    'lucknow': (26.72, 80.80, 27.05, 81.10),
    'nagpur': (21.00, 78.90, 21.25, 79.20),
    'pune': (18.35, 73.65, 18.70, 74.05),
    'kanpur': (26.35, 80.15, 26.55, 80.45),
}

# Order matters for overlapping regions (e.g., noida inside delhi_ncr).
CITY_BBOX_PRIORITY = [
    'noida',
    'delhi_ncr',
    'bengaluru',
    'chennai',
    'mumbai',
    'kolkata',
    'hyderabad',
    'ahmedabad',
    'kochi',
    'jaipur',
    'lucknow',
    'nagpur',
    'pune',
    'kanpur',
]


def _city_from_bbox(lat, lng):
    try:
        lat_f = float(lat)
        lng_f = float(lng)
    except Exception:
        return None

    for city in CITY_BBOX_PRIORITY:
        bbox = CITY_BBOX_FALLBACKS.get(city)
        if not bbox:
            continue
        south, west, north, east = bbox
        if south <= lat_f <= north and west <= lng_f <= east:
            return city
    return None

def extract_all():
    print("Loading OSM Data...", flush=True)
    try:
        with open('assets/india_metro/india_metro_osm_stations.json', 'r', encoding='utf-8') as f:
            data = json.load(f)
    except FileNotFoundError:
        print("Error: OSM data file not found.")
        return

    # Prepare containers
    city_stops = {city: [] for city in CITY_MAPPINGS}
    
    print(f"Processing {len(data)} items...", flush=True)
    
    count_kanpur = 0
    count_added = 0

    for item in data:
        osm = item.get('osm') or {}
        osm_type = str(osm.get('type') or '')
        osm_id = str(osm.get('id') or '')

        lat = item.get('lat')
        lng = item.get('lng')
        if lat is None or lng is None:
            continue

        network = item.get('network')
        operator = item.get('operator')
        line = item.get('line')
        ref = item.get('ref')

        name = item.get('name')
        if name is None:
            name = ''
        name = str(name)

        tags_dict = item.get('tags') or {}
        if not name:
            name = str(tags_dict.get('name', 'Unknown'))

        combined_tag = (
            f"{network or ''} {operator or ''} {line or ''} {ref or ''} {name} {tags_dict}"
        ).lower()

        # Prefer coordinate-based classification when possible.
        matched_city = _city_from_bbox(lat, lng)

        # Otherwise fall back to keyword matching.
        if matched_city is None:
            for city, keywords in CITY_MAPPINGS.items():
                for kw in keywords:
                    if kw.lower() in combined_tag:
                        matched_city = city
                        break
                if matched_city:
                    break

        if not matched_city:
            continue

        if not osm_id:
            continue

        stop_obj = {
            "id": f"OSM_{osm_id}",
            "osmType": osm_type,
            "osmId": osm_id,
            "city": matched_city,
            "name": name,
            "lat": lat,
            "lng": lng,
            "network": network,
            "operator": operator,
            "line": line,
            "ref": ref,
        }
        city_stops[matched_city].append(stop_obj)
        count_added += 1

        if matched_city == 'kanpur':
            count_kanpur += 1

    print(f"Total processed: {count_added}. Kanpur found: {count_kanpur}", flush=True)

    # 1. Overwrite stops.json for each city (Optional for this task but good practice)
    # Skipping to focus on Dart file generation
    
    # 2. Generate Dart file for Dashboard
    dart_content = """// GENERATED FILE - DO NOT EDIT
// Source: india_metro_osm_stations.json
// Generated by: extract_all_stops.py

final List<Map<String, dynamic>> allIndiaStops = [
"""
    
    # Sort cities alphabetically
    sorted_cities = sorted(city_stops.keys())
    
    for city in sorted_cities:
        stops = city_stops[city]
        if not stops: 
            continue
            
        dart_content += f"  // --- {city.replace('_', ' ').title()} ---\n"
        
        # Sort stops by name within city
        sorted_stops = sorted(stops, key=lambda x: x['name'])
        
        for stop in sorted_stops:
            dart_content += f"""  {{
    "id": "{stop['id']}",
        "osmType": "{stop.get('osmType', '')}",
        "osmId": "{stop.get('osmId', '')}",
        "city": "{stop.get('city', city)}",
    "name": "{stop['name'].replace('"', '\\"')}",
    "lat": {stop['lat']},
    "lng": {stop['lng']},
        "network": "{str(stop.get('network') or '').replace('"', '\\"')}",
        "operator": "{str(stop.get('operator') or '').replace('"', '\\"')}",
        "line": "{str(stop.get('line') or '').replace('"', '\\"')}",
        "ref": "{str(stop.get('ref') or '').replace('"', '\\"')}",
  }},
"""

    dart_content += "];\n"

    dart_path = 'lib/all_india_stops.dart'
    with open(dart_path, 'w', encoding='utf-8') as f:
        f.write(dart_content)
    
    print(f"Generated {dart_path} with {sum(len(s) for s in city_stops.values())} total stops.", flush=True)

if __name__ == "__main__":
    extract_all()
