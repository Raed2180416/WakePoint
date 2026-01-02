import json
import os
import sys

# Flush stdout to ensure logs appear immediately
sys.stdout.reconfigure(encoding='utf-8')

print("Script started...", flush=True)

# Ground Truth Data
EXPECTED_STATION_COUNTS = {
    'delhi_ncr': 288,
    'bengaluru': 67,
    'mumbai': 68,
    'kolkata': 58,
    'hyderabad': 57,
    'chennai': 42,
    'ahmedabad': 39,
    'nagpur': 38,
    'pune': 29,
    'kochi': 25,
    'lucknow': 21,
    'jaipur': 11,
    'navi_mumbai': 11,
    'kanpur': 14,
    'agra': 6,
    'indore': 5,
    'patna': 3,
}

CITY_MAPPINGS = {
    'ahmedabad': ['Gujarat Metro', 'Ahmedabad'],
    'bengaluru': ['Namma Metro', 'Bangalore Metro'],
    'chennai': ['Chennai Metro'],
    'delhi_ncr': ['Delhi Metro', 'Noida Metro', 'National Capital Region Transport Corporation', 'NR', 'Rapid Metro Gurgaon'],
    'hyderabad': ['Hyderabad Metro'],
    'jaipur': ['Jaipur Metro'],
    'kochi': ['Kochi Metro'],
    'kolkata': ['Kolkata Metro'],
    'lucknow': ['Lucknow Metro'],
    'mumbai': ['Mumbai Metro', 'MMRDA', 'Mumbai Metro One'],
    'nagpur': ['Nagpur Metro', 'MahaMetro'],
    'navi_mumbai': ['Navi Mumbai Metro', 'CIDCO'],
    'pune': ['Pune Metro'],
    'kanpur': ['Kanpur Metro', 'Uttar Pradesh Metro Rail Corporation'],
    'agra': ['Agra Metro'], 
    'indore': ['Indore Metro', 'Madhya Pradesh Metro Rail Corporation'],
}

def main():
    print("Loading JSON...", flush=True)
    try:
        with open('assets/india_metro/india_metro_osm_stations.json', 'r', encoding='utf-8') as f:
            data = json.load(f)
        print(f"Loaded {len(data)} items.", flush=True)
    except Exception as e:
        print(f"Failed to load JSON: {e}", flush=True)
        return

    detected_counts = {city: 0 for city in EXPECTED_STATION_COUNTS}
    orphaned_stops = []
    potential_missing = {'kanpur': [], 'agra': [], 'indore': [], 'patna': []}

    print("Processing items...", flush=True)
    for item in data:
        network = str(item.get('network', '')).lower()
        operator = str(item.get('operator', '')).lower()
        name = item.get('name')
        if name is None: name = ''
        name = str(name)
        
        tags = item.get('tags')
        if tags is None: tags = ''
        tags = str(tags).lower()
        
        full_str = f"{network} {operator} {name} {tags}"
        
        matched_city = None
        for city, keywords in CITY_MAPPINGS.items():
            for kw in keywords:
                if kw.lower() in full_str:
                    matched_city = city
                    break
            if matched_city:
                break
        
        if matched_city:
            if matched_city == 'gurgaon': matched_city = 'delhi_ncr' 
            if matched_city in detected_counts:
                detected_counts[matched_city] += 1
        else:
            # Check for missing cities
            for missing_city in potential_missing:
                if missing_city in full_str:
                    potential_missing[missing_city].append(name)
            
            # Identify orphans
            if 'station' in full_str or 'metro' in full_str:
                orphaned_stops.append(f"{name} ({network}/{operator})")

    # Write Report
    print("Writing report...", flush=True)
    try:
        with open('coverage_report.txt', 'w', encoding='utf-8') as f:
            f.write("METRO COVERAGE REPORT\n")
            f.write("=====================\n\n")
            f.write(f"{'CITY':<15} | {'FOUND':<10} | {'EXPECTED':<10} | {'STATUS':<10}\n")
            f.write("-" * 55 + "\n")
            
            for city, expected in EXPECTED_STATION_COUNTS.items():
                found = detected_counts.get(city, 0)
                status = "OK"
                if found < expected * 0.8: status = "LOW"
                if found == 0: status = "MISSING"
                f.write(f"{city:<15} | {found:<10} | {expected:<10} | {status:<10}\n")
            
            f.write("\n\nMISSING CITY CANDIDATES\n")
            f.write("-----------------------\n")
            for city, stops in potential_missing.items():
                f.write(f"{city.capitalize()}: {len(stops)} candidates\n")
                if stops:
                    f.write(f"  Samples: {', '.join(stops[:5])}\n")
            
            f.write("\n\nORPHANED STOPS (Sample)\n")
            f.write("-----------------------\n")
            unique_orphans = sorted(list(set(orphaned_stops)))
            for s in unique_orphans[:20]:
                f.write(f"{s}\n")
                
        print("Report written to coverage_report.txt", flush=True)
    except Exception as e:
        print(f"Failed to write report: {e}", flush=True)

if __name__ == "__main__":
    main()
