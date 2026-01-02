import os

file_path = r'd:\WakePoint\lib\services\trackingservice.dart'

with open(file_path, 'r', encoding='utf-8') as f:
    lines = f.readlines()

new_lines = []
skip = False
delete_buffer = False

# Helper to find index
def find_index(start_idx, pattern):
    for i in range(start_idx, len(lines)):
        if pattern in lines[i]:
            return i
    return -1

# 1. Remove _buildCumulativeStops
start_stops = find_index(0, 'List<double> _buildCumulativeStops')
end_stops = find_index(start_stops, 'Future<void> registerRouteRaw')
# Backup a bit to keep the @visibleForTesting annotation for registerRouteRaw
if end_stops != -1:
    # Find @visibleForTesting before registerRouteRaw
    for i in range(end_stops, start_stops, -1):
        if '@visibleForTesting' in lines[i]:
            end_stops = i
            break

if start_stops != -1 and end_stops != -1:
    print(f"Removing _buildCumulativeStops: lines {start_stops} to {end_stops}")
    # Replace lines with nothing (exclude end_stops)
    # We construct a set of indices to ignore
    ignore_indices = set(range(start_stops, end_stops))
else:
    print("Could not find _buildCumulativeStops block")
    ignore_indices = set()

# 2. Remove registerRouteRaw legacy block
marker_raw = 'activate: true, // RAW is always active in tests'
idx_raw = find_index(0, marker_raw)
idx_return_raw = find_index(idx_raw, 'return;')
idx_comment_start_raw = find_index(idx_return_raw, '/*')
idx_comment_end_raw = find_index(idx_comment_start_raw, '*/')

if idx_raw != -1 and idx_return_raw != -1 and idx_comment_start_raw != -1 and idx_comment_end_raw != -1:
     print(f"Removing registerRouteRaw legacy: lines {idx_return_raw} to {idx_comment_end_raw}")
     ignore_indices.update(range(idx_return_raw, idx_comment_end_raw + 1))

# 3. Remove registerRouteFromDirections legacy block
marker_dir = 'activate: activateRoute,'
idx_dir = find_index(0, marker_dir)
# Start search for return/comment AFTER the previous removals? No, searching from 0 is fine if unique.
# Actually duplicates exist? No these markers are inside methods.
# Wait, 'activate: activateRoute,' might be used elsewhere? 
# In registerRoute call inside registerRouteFromDirections.
# But I need the one followed by `return;`.
# Let's search from idx_dir.

if idx_dir != -1:
    idx_return_dir = find_index(idx_dir, 'return;')
    idx_comment_start_dir = find_index(idx_return_dir, '/*')
    # Find */ before the LAST } of the function? 
    # Just find next */
    idx_comment_end_dir = find_index(idx_comment_start_dir, '*/')

    if idx_return_dir != -1 and idx_comment_start_dir != -1 and idx_comment_end_dir != -1:
        print(f"Removing registerRouteFromDirections legacy: lines {idx_return_dir} to {idx_comment_end_dir}")
        ignore_indices.update(range(idx_return_dir, idx_comment_end_dir + 1))
    else:
        print("Could not find registerRouteFromDirections legacy block end keys")

# Write output
with open(file_path, 'w', encoding='utf-8') as f:
    for i, line in enumerate(lines):
        if i not in ignore_indices:
            f.write(line)

print("Done.")
