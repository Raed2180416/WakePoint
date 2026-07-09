import re
import json

path = "d:/WakePoint/lib/all_india_stops.dart"

city_counts = {}

with open(path, 'r', encoding='utf-8') as f:
    content = f.read()

# Naive parsing because it's a Dart file, but structured enough.
# We look for "city": "name" and "status": "active"
# Since it's a list of maps, we can try to separate objects.

# Regex to find each map block is hard, but we can iterate line by line or use regex for keys.
# Let's simple regex for city and status in proximity? No, unsafe.

# Let's assume standard formatting from the file view:
#   {
#     "id": ...,
#     "city": "agra",
#     ...
#     "status": "active",
#   },

# We can scan for "city": "..." and then look ahead for status.
# Or just count all occurrences if we assume all entries are well formed.

# Better: Splitting by "{" 
blocks = content.split('{')
for block in blocks:
    if '"city":' in block:
        # Extract city
        m_city = re.search(r'"city":\s*"([^"]+)"', block)
        if m_city:
            city = m_city.group(1).lower()
            
            # Check status
            m_status = re.search(r'"status":\s*"([^"]+)"', block)
            status = m_status.group(1).lower() if m_status else "unknown"
            
            if status == "active":
                city_counts[city] = city_counts.get(city, 0) + 1

print(f"{'CITY':<15} | {'ACTIVE STOPS':<15}")
print("-" * 35)
for city, count in sorted(city_counts.items(), key=lambda x: x[1], reverse=True):
    print(f"{city:<15} | {count:<15}")
