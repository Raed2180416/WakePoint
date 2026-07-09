import json
import re
import requests # Needs to be installed or use standard lib approach?
# Standard lib approach for http request in python usually is urllib, but `requests` is common. 
# Since I can't guarantee `requests` is installed on user machine without checking, I will use `urllib.request`.
import urllib.request
import urllib.parse
import time

API_KEY = "YOUR_API_KEY_HERE" # User will need to provide this
PATH = "d:/WakePoint/lib/all_india_stops.dart"

def load_stops():
    with open(PATH, 'r', encoding='utf-8') as f:
        content = f.read()
    
    entries = []
    lines = content.splitlines()
    curr_obj = {}
    in_obj = False
    
    for line in lines:
        sline = line.strip()
        if sline == "{":
            in_obj = True
            curr_obj = {}
        elif sline.startswith("},") or (sline == "}" and in_obj):
            in_obj = False
            entries.append(curr_obj)
        elif in_obj:
            m = re.match(r'"([^"]+)":\s*(.+),?', sline)
            if m:
                k = m.group(1)
                v = m.group(2).strip(',').strip('"')
                curr_obj[k] = v
    return entries

def check_google_maps(station_name, city, lat, lng, api_key):
    query = f"{station_name} Metro Station, {city}"
    enc_query = urllib.parse.quote(query)
    url = f"https://maps.googleapis.com/maps/api/place/findplacefromtext/json?input={enc_query}&inputtype=textquery&fields=geometry,name,formatted_address&key={api_key}"
    
    try:
        with urllib.request.urlopen(url) as response:
            data = json.loads(response.read().decode())
            
        if data['status'] == 'OK' and data['candidates']:
            cand = data['candidates'][0]
            loc = cand['geometry']['location']
            g_lat = loc['lat']
            g_lng = loc['lng']
            
            # Haversine approx
            d_lat = abs(float(lat) - g_lat) * 111000
            d_lng = abs(float(lng) - g_lng) * 111000 # Rough approx
            dist = (d_lat**2 + d_lng**2)**0.5
            
            return {
                "found": True,
                "g_lat": g_lat,
                "g_lng": g_lng,
                "dist_m": dist,
                "address": cand['formatted_address']
            }
        return {"found": False, "status": data['status']}
    except Exception as e:
        return {"found": False, "error": str(e)}

if __name__ == "__main__":
    print("This script requires a Google Maps API Key.")
    
    # Placeholder for logic
    stops = load_stops()
    print(f"Loaded {len(stops)} stops.")
    # In real usage, we would loop through questionable stops.
