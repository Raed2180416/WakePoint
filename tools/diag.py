import sys
print("Step 1: Start", flush=True)
try:
    import json
    print("Step 2: Imports done", flush=True)
    with open('assets/india_metro/india_metro_osm_stations.json', 'r', encoding='utf-8') as f:
        print("Step 3: File opened", flush=True)
        data = json.load(f)
        print(f"Step 4: Loaded {len(data)} items", flush=True)
except Exception as e:
    print(f"ERROR: {e}", flush=True)
print("Step 5: Done", flush=True)
