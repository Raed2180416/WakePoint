import json
import os
import sys

# Flush output
sys.stdout.reconfigure(encoding='utf-8')

CITY_MAPPINGS = {
    'kanpur': ['Kanpur Metro', 'Uttar Pradesh Metro Rail Corporation'],
}

def extract_debug():
    print("DEBUG: Loading OSM Data...", flush=True)
    try:
        with open('assets/india_metro/india_metro_osm_stations.json', 'r', encoding='utf-8') as f:
            data = json.load(f)
    except Exception as e:
        print(f"Error: {e}")
        return

    print(f"DEBUG: Processing {len(data)} items...", flush=True)
    
    count_kanpur = 0
    
    for i, item in enumerate(data):
        network = str(item.get('network', ''))
        operator = str(item.get('operator', ''))
        name = item.get('name')
        if name is None: name = ''
        name = str(name)
        
        tags = item.get('tags')
        if tags is None: tags = ''
        tags = str(tags)
        
        combined_tag = (network + " " + operator + " " + name + " " + tags).lower()
        
        if i < 3:
            print(f"DEBUG Item {i}: {combined_tag[:100]}...", flush=True)
            
        if 'kanpur' in combined_tag:
            count_kanpur += 1
            print(f"DEBUG: FOUND KANPUR! {name}", flush=True)
            
    print(f"DEBUG: Total Kanpur matches: {count_kanpur}", flush=True)

if __name__ == "__main__":
    extract_debug()
