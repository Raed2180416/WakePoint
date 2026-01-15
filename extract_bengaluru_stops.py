
import json

def extract_stops():
    try:
        with open('assets/india_metro/india_metro_osm_stations.json', 'r', encoding='utf-8') as f:
            data = json.load(f)
        
        bengaluru_stops = []
        for item in data:
            network = item.get('network')
            operator = item.get('operator')
            
            is_bengaluru = False
            if network and 'Namma Metro' in network:
                is_bengaluru = True
            elif operator and 'Bangalore Metro' in operator:
                is_bengaluru = True
            
            if is_bengaluru:
                stop_id = str(item.get('osm', {}).get('id', ''))
                name = item.get('name', 'Unknown')
                lat = item.get('lat')
                lng = item.get('lng')
                
                if lat and lng:
                    bengaluru_stops.append({
                        "id": f"OSM_{stop_id}",
                        "name": name,
                        "lat": lat,
                        "lng": lng
                    })
        
        bengaluru_stops.sort(key=lambda x: x['name'])
        
        # Write to output json
        output_data = {"stops": bengaluru_stops}
        with open('assets/india_metro/bengaluru_stops.json', 'w', encoding='utf-8') as f:
            json.dump(output_data, f, indent=2)
            
        print(f"Success: Overwrote stops.json with {len(bengaluru_stops)} stations from OSM")

    except Exception as e:
        print(f"Error: {e}")

if __name__ == "__main__":
    extract_stops()
