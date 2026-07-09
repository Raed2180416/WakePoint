import json
import time
import random
import re

DART_FILE = "d:/WakePoint/lib/all_india_stops.dart"
JSON_FILE = "d:/WakePoint/scripts/scraped_metro_data.json"

def generate_id():
    ts = int(time.time() * 1000)
    rnd = random.randint(100, 999)
    return f"SCRAPED_{ts}_{rnd}"

def format_entry(entry):
    # Ensure line has the dot if missing, or keep scraper's if nice.
    # Scraper got "◙  Red Line" likely.
    # Dart file has "&#x25D9;  Blue Line".
    # We can encode the symbol or just use text.
    # The symbol ◙ is U+25D9.
    
    
    line_name = entry['line'].replace("◙", "&#x25D9;").strip()
    clean_line_name = entry['line'].replace("◙", "").strip()
    
    city_display = entry['city'].title() + " Metro"
    
    # Refined color logic
    color = entry['lineColor'] # Default from scraper (generic)
    
    # City specific overrides
    if entry['city'] == 'chennai':
        if "Blue" in clean_line_name: color = "0xFF00539C"
        elif "Green" in clean_line_name: color = "0xFF009D57"
        
    elif entry['city'] == 'mumbai':
        if "Blue" in clean_line_name: color = "0xFF00A3E0" # Line 1
        elif "Yellow" in clean_line_name: color = "0xFFFFD700" # Line 2
        elif "Aqua" in clean_line_name: color = "0xFF2CD5C4" # Line 3
        elif "Green" in clean_line_name: color = "0xFF009900" # Line 4
        elif "Orange" in clean_line_name: color = "0xFFFF9900" # Line 5
        elif "Pink" in clean_line_name: color = "0xFFFF66CC" # Line 6
        elif "Red" in clean_line_name: color = "0xFFDA291C" # Line 7
        
    elif entry['city'] == 'kolkata':
        if "Blue" in clean_line_name: color = "0xFF00539C" # North-South
        elif "Green" in clean_line_name: color = "0xFF009D57" # East-West
        elif "Purple" in clean_line_name: color = "0xFFA020F0"
        elif "Yellow" in clean_line_name: color = "0xFFF6D71A"
        elif "Orange" in clean_line_name: color = "0xFFF46808"

    elif entry['city'] == 'navimumbai':
         # Navi Mumbai has Line 1 which is often cited as generic Metro but let's check.
         # It's often just "Line 1".
         color = "0xFF00539C" # Default blueish for now if unsure, or keep scraper default.
         pass
         
    return f"""  {{
    "id": "{generate_id()}",
    "osmType": "scraped",
    "osmId": "",
    "city": "{entry['city']}",
    "name": "{entry['name']}",
    "lat": {entry['lat']},
    "lng": {entry['lng']},
    "network": "{city_display}",
    "operator": "Scraped",
    "line": "{line_name}",
    "lineColor": "{color}",
    "status": "active",
    "ref": "",
  }},"""

def main():
    with open(JSON_FILE, 'r', encoding='utf-8') as f:
        data = json.load(f)
        
    by_city = {}
    for item in data:
        c = item['city']
        if c not in by_city: by_city[c] = []
        by_city[c].append(item)
        
    with open(DART_FILE, 'r', encoding='utf-8') as f:
        lines = f.readlines()
        
    new_lines = []
    i = 0
    
    # We need to process existing sections and append new ones.
    # For simplification, we will build a new list of lines.
    
    # Identify existing cities positions
    city_headers = {}
    for idx, line in enumerate(lines):
        if "// ---" in line:
            # Extract city name
            m = re.search(r'// --- ([A-Z]+) ---', line)
            if m:
                city_headers[m.group(1)] = idx
    
    sorted_headers = sorted(city_headers.items(), key=lambda x: x[1])
    
    # We will reconstruct the file.
    # But checking for missing cities is easier if we just iterate lines and handle replacements.
    
    processed_cities = set()
    
    while i < len(lines):
        line = lines[i]
        
        # Check if this is a header we want to replace (DELHI)
        is_target_header = False
        target_city_key = None
        
        if "// ---" in line:
            for city_key in by_city.keys():
                if f"// --- {city_key.upper()} ---" in line:
                    is_target_header = True
                    target_city_key = city_key
                    break
        
        if is_target_header:
            print(f"Replacing section for {target_city_key}")
            new_lines.append(line) # Keep header
            processed_cities.add(target_city_key)
            
            # Add new data
            for entry in by_city[target_city_key]:
                new_lines.append(format_entry(entry) + "\n")
            
            # Skip old data until next header or end of list
            i += 1
            while i < len(lines):
                if "// ---" in lines[i] or "];" in lines[i]:
                    break
                i += 1
            continue
            
        # If it's the end of list, we append missing cities
        if "];" in line.strip() and i == len(lines) - 1: # Assuming ]; is near end
             pass 
             
        new_lines.append(line)
        i += 1

    # Now handle appended cities (those not in processed_cities)
    # searching for the closing bracket "];"
    # We'll insert before the last occurrence of "];"
    
    # Find last ];
    insert_idx = -1
    for idx in range(len(new_lines)-1, -1, -1):
        if "];" in new_lines[idx]:
            insert_idx = idx
            break
            
    if insert_idx != -1:
        to_insert = []
        for city_key in by_city.keys():
            if city_key not in processed_cities:
                print(f"Appending section for {city_key}")
                to_insert.append(f"  // --- {city_key.upper()} ---\n")
                for entry in by_city[city_key]:
                    to_insert.append(format_entry(entry) + "\n")
        
        # Insert before ];
        new_lines[insert_idx:insert_idx] = to_insert
    else:
        print("Error: Could not find closing bracket ];")

    with open(DART_FILE, 'w', encoding='utf-8') as f:
        f.writelines(new_lines)
    
    print("Update complete.")

if __name__ == "__main__":
    main()
