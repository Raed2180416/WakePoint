import json

keyword = "kanpur"
# Force utf-8 file write
with open('kanpur_dump.txt', 'w', encoding='utf-8') as outfile:
    outfile.write(f"Searching for '{keyword}' in JSON...\n")
    try:
        with open('assets/india_metro/india_metro_osm_stations.json', 'r', encoding='utf-8') as f:
            data = json.load(f)
            
        found_count = 0
        for item in data:
            s = json.dumps(item).lower()
            if keyword in s:
                outfile.write("--- ITEM FOUND ---\n")
                outfile.write(json.dumps(item, indent=2) + "\n")
                found_count += 1
                if found_count >= 5: break
                
        outfile.write(f"Total found matching '{keyword}': {found_count} (showing max 5)\n")

    except Exception as e:
        outfile.write(str(e) + "\n")
print("Done")
