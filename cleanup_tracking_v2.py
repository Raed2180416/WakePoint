import os

file_path = r'd:\WakePoint\lib\services\trackingservice.dart'

with open(file_path, 'r', encoding='utf-8') as f:
    lines = f.readlines()

ignore_indices = set()

def find_line_index(start_idx, substr):
    for i in range(start_idx, len(lines)):
        if substr in lines[i]:
            return i
    return -1

# 1. _polylineLengthMeters
idx_poly = find_line_index(0, 'double _polylineLengthMeters(List<LatLng> pts) {')
if idx_poly != -1:
    depth = 0
    end_poly = -1
    for i in range(idx_poly, len(lines)):
        line = lines[i]
        depth += line.count('{')
        depth -= line.count('}')
        if depth == 0 and '}' in line:
            end_poly = i
            break
    
    if end_poly != -1:
        print(f"Removing _polylineLengthMeters: lines {idx_poly} to {end_poly}")
        ignore_indices.update(range(idx_poly, end_poly + 1))
else:
    print("_polylineLengthMeters not found (or already removed?)")

# 2. _isMetroStep
idx_metro = find_line_index(0, 'static bool _isMetroStep(Map<String, dynamic> step) {')
if idx_metro != -1:
    depth = 0
    end_metro = -1
    for i in range(idx_metro, len(lines)):
        line = lines[i]
        depth += line.count('{')
        depth -= line.count('}')
        if depth == 0 and '}' in line:
            end_metro = i
            break
    if end_metro != -1:
        print(f"Removing _isMetroStep: lines {idx_metro} to {end_metro}")
        ignore_indices.update(range(idx_metro, end_metro + 1))
else:
    print("_isMetroStep not found")

# 3. registerRouteFromDirections legacy block
# Marker: activate: activateRoute,
idx_act = find_line_index(0, 'activate: activateRoute,')
if idx_act != -1:
    idx_ret = find_line_index(idx_act, 'return;')
    idx_start_comment = find_line_index(idx_ret, '/*')
    
    # Find matching */
    idx_end_comment = -1
    if idx_start_comment != -1:
        for i in range(idx_start_comment, len(lines)):
            if '*/' in lines[i]:
                idx_end_comment = i
                break
    
    if idx_ret != -1 and idx_start_comment != -1 and idx_end_comment != -1:
        print(f"Removing registerRouteFromDirections legacy: lines {idx_ret} to {idx_end_comment}")
        ignore_indices.update(range(idx_ret, idx_end_comment + 1))
    else:
        print(f"Failed to find markers for Directions legacy: ret={idx_ret}, start={idx_start_comment}, end={idx_end_comment}")
else:
    print("Could not find 'activate: activateRoute,'")

# Write back
with open(file_path, 'w', encoding='utf-8') as f:
    for i, line in enumerate(lines):
        if i not in ignore_indices:
            f.write(line)
            
print("Done updated script.")
