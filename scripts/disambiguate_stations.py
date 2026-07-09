import re

path = "d:/WakePoint/lib/all_india_stops.dart"

with open(path, 'r', encoding='utf-8') as f:
    lines = f.readlines()

new_lines = []
mumbai_entries = []
in_mumbai = False
obj_start = -1

# First pass: Identify duplicates in Mumbai
name_counts = {}
mumbai_indices = []

curr_line_start = 0
in_obj = False
curr_obj = {}

# We need a robust parser that keeps line numbers
entries = [] # (start_line, end_line, dict)

for i, line in enumerate(lines):
    sline = line.strip()
    if sline == "{":
        curr_line_start = i
        in_obj = True
        curr_obj = {}
    elif sline.startswith("},") or (sline == "}" and in_obj):
        in_obj = False
        if curr_obj.get("city") == "mumbai":
            entries.append((curr_line_start, i, curr_obj))
    elif in_obj:
        m = re.match(r'"([^"]+)":\s*(.+),?', sline)
        if m:
            k = m.group(1)
            v = m.group(2).rstrip(',')
            if v.startswith('"') and v.endswith('"'):
                v = v[1:-1]
            curr_obj[k] = v

# specific names to fix
targets = ["Dahisar East", "Andheri", "Marol Naka", "Ghatkopar", "Aarey JVLR", "Saki Naka", "Kurar", "Gandhinagar"] 
# (Add others as needed from debug output)

# Map names to list of entries
name_map = {}
for start, end, obj in entries:
    name = obj.get("name")
    if name in name_map:
        name_map[name].append((start, end, obj))
    else:
        name_map[name] = [(start, end, obj)]

# Edits
edits = {} # line_no -> new_content

for name, items in name_map.items():
    if len(items) > 1:
        print(f"Disambiguating {name} ({len(items)} entries)")
        for start, end, obj in items:
            line_raw = obj.get("line", "")
            # Extract line name "Blue Line" from "&#x25D9;  Blue Line"
            line_clean = line_raw.replace("&#x25D9;", "").replace("◙", "").strip()
            
            # Keep original name for creating composite
            new_name = f"{name} ({line_clean})"
            
            # Find the line with "name": "..."
            for j in range(start, end+1):
                if '"name":' in lines[j]:
                    # simplistic replacement
                    edits[j] = lines[j].replace(f'"{name}"', f'"{new_name}"')
                    break

# Write back
with open(path, 'w', encoding='utf-8') as f:
    for i, line in enumerate(lines):
        if i in edits:
            f.write(edits[i])
        else:
            f.write(line)

print("Disambiguation complete.")
