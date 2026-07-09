import requests
import re
import json

embed_url = "https://www.google.com/maps/embed/v1/place?key=AIzaSyBCY3GiB2MjOvzS16XfrH3OvWNAFmt9Y9c&q=Shaheed+Sthal+(New+Bus+Adda)+Metro+Station+Ghaziabad&center=28.6705,77.415882"

print(f"Fetching: {embed_url}")

headers = {
    "Referer": "https://www.yometro.com/",
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36"
}

try:
    response = requests.get(embed_url, headers=headers)
    html = response.text
    # print(html[:1000])
    
    # Look for patterns like [lat, lng]
    # Google often puts data in JSON-like arrays. 
    # Valid coords in Delhi are approx 28.something, 77.something.
    
    matches = re.findall(r'\[\s*(-?\d+\.\d+)\s*,\s*(-?\d+\.\d+)\s*\]', html)
    print(f"Found {len(matches)} coordinate-like pairs.")
    for m in matches:
        lat = float(m[0])
        lng = float(m[1])
        if 28.0 <= lat <= 29.0 and 76.0 <= lng <= 78.0:
            print(f"Candidate: {lat}, {lng}")

    # Also look for the initEmbed info specifically
    # It might be in specific variable
    
except Exception as e:
    print(f"Error: {e}")
