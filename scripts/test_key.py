import requests

key = "AIzaSyBCY3GiB2MjOvzS16XfrH3OvWNAFmt9Y9c"
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
