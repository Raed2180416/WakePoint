import json
import re

path = "d:/WakePoint/lib/all_india_stops.dart"

with open(path, 'r', encoding='utf-8') as f:
    content = f.read()

# Since it's a Dart file with JSON-like maps, let's extract blocks
entries = []
lines = content.splitlines()
current_obj = {}
in_obj = False

for i, line in enumerate(lines):
    line = line.strip()
    if line == "{":
        in_obj = True
        current_obj = {"_line": i+1}
        continue
    if line.startswith("},") or (line == "}" and in_obj):
        in_obj = False
        if current_obj.get("city") == "mumbai":
            entries.append(current_obj)
        current_obj = {}
        continue
    
    if in_obj:
        m = re.match(r'"([^"]+)":\s*(.+),?', line)
        if m:
            k = m.group(1)
            v = m.group(2).rstrip(',')
            if v.startswith('"') and v.endswith('"'):
                v = v[1:-1]
            current_obj[k] = v

print(f"Found {len(entries)} Mumbai entries.")
ids = {}
names = {}

for e in entries:
    name = e.get("name")
    eid = e.get("id")
    line_num = e.get("_line")
    
    if name in names:
        print(f"DUPLICATE NAME: {name} at lines {names[name]} and {line_num}")
    else:
        names[name] = line_num
        
    if eid in ids:
        print(f"DUPLICATE ID: {eid} at lines {ids[eid]} and {line_num}")
    else:
        ids[eid] = line_num

    if name == "Chakala JB Nagar":
        print(f"CHAKALA FOUND: {e}")

    # Check colors
    line_name = e.get("line", "")
    color = e.get("lineColor", "")
    # print(f"{name} ({line_name}): {color}")
