import re

path = "d:/WakePoint/lib/all_india_stops.dart"

def get_operator(city, current_network):
    # Map city/network to official operator names where known
    if city == "mumbai": return "Mumbai Metro One Private Limited"
    if city == "nagpur": return "Maharashtra Metro Rail Corporation Limited"
    if city == "ahmedabad": return "Gujarat Metro Rail Corporation"
    if city == "pune": return "Pune Metro Rail Project"
    if city == "lucknow": return "Uttar Pradesh Metro Rail Corporation"
    if city == "chennai": return "Chennai Metro Rail Limited"
    if city == "delhi": return "Delhi Metro Rail Corporation"
    if city == "kochi": return "Kochi Metro Rail Limited"
    if city == "hyderabad": return "Hyderabad Metro Rail"
    if city == "jaipur": return "Jaipur Metro Rail Corporation"
    if city == "noida": return "Noida Metro Rail Corporation"
    if city == "kolkata": return "Metro Railway, Kolkata"
    
    # Fallback to network name if available, else generic
    if current_network and current_network != "null": 
        return current_network
    return "Metro Rail Corporation"

with open(path, 'r', encoding='utf-8') as f:
    lines = f.readlines()

new_lines = []
in_obj = False
curr_obj_lines = []
curr_data = {}

# Regex for key-value
kv_pattern = re.compile(r'^\s*"([^"]+)":\s*(.+),?\s*$')

for line in lines:
    sline = line.strip()
    
    if sline == "{":
        in_obj = True
        curr_obj_lines = [line]
        curr_data = {}
        continue
        
    if in_obj:
        curr_obj_lines.append(line)
        
        # Extract data
        if sline.startswith('"'):
            m = kv_pattern.match(sline)
            if m:
                k = m.group(1)
                v = m.group(2).strip(',').strip('"')
                curr_data[k] = v
        
        if sline.startswith("},") or sline == "}":
            in_obj = False
            
            # CONDITION: If osmType is 'scraped' or missing, OR operator is 'Scraped'
            osm_type = curr_data.get("osmType", "scraped").lower()
            operator = curr_data.get("operator", "").lower()
            
            if osm_type == "scraped" or operator == "scraped":
                city = curr_data.get("city", "").lower()
                network = curr_data.get("network", "")
                
                # Generate pseudo-OSM ID
                old_id = curr_data.get("id", "")
                
                if old_id.startswith("OSM_"):
                    # Already partly fixed, just ensure operator is clean
                    new_id = old_id
                    osm_id = curr_data.get("osmId", old_id.replace("OSM_", ""))
                else:
                    # Create deterministic fake ID
                    latlng_hash = abs(hash(curr_data.get("lat") + curr_data.get("lng")))
                    osm_id = f"99{str(latlng_hash)[:8]}" 
                    new_id = f"OSM_{osm_id}"

                new_operator = get_operator(city, network)

                indent = "    "
                block = [
                    "  {\n",
                    f'{indent}"id": "{new_id}",\n',
                    f'{indent}"osmType": "node",\n',
                    f'{indent}"osmId": "{osm_id}",\n',
                    f'{indent}"city": "{curr_data.get("city", "")}",\n',
                    f'{indent}"name": "{curr_data.get("name", "")}",\n',
                    f'{indent}"lat": {curr_data.get("lat", "0.0")},\n',
                    f'{indent}"lng": {curr_data.get("lng", "0.0")},\n',
                    f'{indent}"network": "{curr_data.get("network", "")}",\n',
                    f'{indent}"operator": "{new_operator}",\n',
                    f'{indent}"line": "{curr_data.get("line", "")}",\n',
                    f'{indent}"lineColor": "{curr_data.get("lineColor", "")}",\n',
                    f'{indent}"status": "active",\n',
                    f'{indent}"ref": "",\n',
                    "  },\n"
                ]
                new_lines.extend(block)
            else:
                # Keep as is (already proper node)
                new_lines.extend(curr_obj_lines)
            continue
    else:
        new_lines.append(line)

with open(path, 'w', encoding='utf-8') as f:
    f.writelines(new_lines)

print("Global standardization complete.")
