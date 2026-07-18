import os

import requests

# Dev-only experiment. The key is read from the environment — never hardcode it.
key = os.environ.get("GMAPS_KEY", "")
address = "Shaheed Sthal (New Bus Adda) Metro Station Ghaziabad"
url = f"https://maps.googleapis.com/maps/api/geocode/json?address={address}&key={key}"

print(f"Testing URL: {url}")

headers = {
    "Referer": "https://www.yometro.com/"
}

try:
    response = requests.get(url, headers=headers)
    print(f"Status: {response.status_code}")
    print(response.text)
except Exception as e:
    print(f"Error: {e}")
