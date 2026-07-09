import re
import json
from collections import defaultdict

PATH = "d:/WakePoint/lib/all_india_stops.dart"

def parse_dart_file(path):
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()

    # Split by simple object identifiers or lines. 
    # Since the formatting is quite regular, line processing might be safer than naive regex split.
    
    cities = defaultdict(list)
    current_city = "unknown"
    
    # We can rely on the city headers we saw earlier: // --- CITY ---
    lines = content.splitlines()
    
    current_obj = {}
    in_obj = False
    
    for line in lines:
        stripped = line.strip()
        
        # Check for city header
        m_header = re.search(r'// --- ([A-Z]+) ---', line)
        if m_header:
            # We don't strictly set city from header because the objects have "city" key,
            # but it helps for context.
            pass

        if stripped == "{":
            in_obj = True
            current_obj = {}
            continue
            
        if stripped.startswith("},") or (stripped == "}" and in_obj):
            in_obj = False
            if "city" in current_obj and "name" in current_obj:
                cities[current_obj["city"].lower()].append(current_obj)
            continue
            
        if in_obj:
            # Extract key-values
            # Key: "key": "value", or "key": value,
            m_kv = re.match(r'"([^"]+)":\s*(.+),?', stripped)
            if m_kv:
                k = m_kv.group(1)
                v = m_kv.group(2).rstrip(',')
                
                # Clean strings
                if v.startswith('"') and v.endswith('"'):
                    v = v[1:-1]
                
                current_obj[k] = v

    return cities

def analyze_city(city_name, stations):
    # normalize names
    # Removing "Metro Station" etc.
    
    unique_stations = defaultdict(list)
    
    for s in stations:
        # Check status
        status = s.get("status", "active").lower() # Default to active if missing
        if status not in ["active", "operational", ""]:
            # If explicit status exists and is not active, skip?
            # But let's be generous for the audit.
            # print(f"Skipping status: {status}")
            pass
            
        name = s['name'].strip()
        # Normalize: remove "Metro Station", extra spaces, case insensitive
        norm_name = re.sub(r'metro station', '', name, flags=re.IGNORECASE).strip().lower()
        norm_name = re.sub(r'\s+', ' ', norm_name)
        
        unique_stations[norm_name].append(s)
        
    unique_count = len(unique_stations)
    interchanges = []
    
    for name, entries in unique_stations.items():
        if len(entries) > 1:
            # Check if lines are different
            lines = set()
            for e in entries:
                lines.add(e.get('line', 'Unknown').replace('&#x25D9;', '').replace('◙', '').strip())
            
            if len(lines) > 1:
                # It's an interchange
                display_name = entries[0]['name'] # Pick one original name
                interchanges.append({
                    "name": display_name,
                    "lines": list(lines),
                    "count": len(entries)
                })

    # Line breakdown
    line_counts = defaultdict(int)
    for s in stations:
        # Check status
        status = s.get("status", "active").lower()
        if status not in ["active", "operational", ""]: continue
        
        line_raw = s.get('line', 'Unknown').replace('&#x25D9;', '').replace('◙', '').strip()
        # Clean up "Main Line", "Branch Line" suffix if desired, or keep specific?
        # Keeping specific helps identify "Green Branch" vs "Green Main"
        line_counts[line_raw] += 1

    return {
        "total_entries": len(stations),
        "unique_active_stations": unique_count,
        "interchanges": interchanges,
        "lines": dict(line_counts)
    }

def main():
    cities_data = parse_dart_file(PATH)
    
    report = {}
    
    print(f"{'CITY':<15} | {'UNIQUE':<8} | {'ENTRIES':<8} | {'INTERCHANGES':<50}")
    print("-" * 100)
    
    for city in sorted(cities_data.keys()):
        stats = analyze_city(city, cities_data[city])
        report[city] = stats
        
        interchange_summary = ", ".join([f"{i['name']} ({len(i['lines'])})" for i in stats['interchanges'][:3]])
        if len(stats['interchanges']) > 3:
            interchange_summary += f", +{len(stats['interchanges'])-3} more"
            
        print(f"{city:<15} | {stats['unique_active_stations']:<8} | {stats['total_entries']:<8} | {interchange_summary}")

    # Dump full details to JSON
    with open("d:/WakePoint/scripts/coverage_report.json", 'w', encoding='utf-8') as f:
        json.dump(report, f, indent=2)


if __name__ == "__main__":
    main()
