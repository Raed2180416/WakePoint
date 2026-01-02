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

# Correct marker for the DELEGATION call
marker = 'activateRoute: activateRoute,'
idx_act = find_line_index(0, marker)

if idx_act != -1:
    print(f"Found marker at {idx_act}: {lines[idx_act]}")
    # Search next 10 lines for return;
    idx_ret = -1
    for i in range(idx_act, min(idx_act + 10, len(lines))):
        if 'return;' in lines[i]:
            idx_ret = i
            break
            
    if idx_ret != -1:
        print(f"Found return at {idx_ret}: {lines[idx_ret]}")
        idx_comment_start = find_line_index(idx_ret, '/*')
        
        # Search for closing */
        # It's far down, so search to end of file
        idx_comment_end = -1
        if idx_comment_start != -1:
            for i in range(idx_comment_start, len(lines)):
                if '*/' in lines[i]:
                    idx_comment_end = i
        
        # Note: I want the LAST */? 
        # No, the first one after the start comment is enough provided comments don't nest.
        # But wait, did I use /* inside the block? Probably not.
        # Previous view showed */ at 3426.
        # So finding the first one is correct.
        
        if idx_comment_start != -1 and idx_comment_end != -1:
             print(f"Removing lines {idx_ret} to {idx_comment_end}")
             ignore_indices.update(range(idx_ret, idx_comment_end + 1))
        else:
             print(f"Failed finding comments: start={idx_comment_start}, end={idx_comment_end}")
    else:
        print("Failed finding return;")
else:
    print("Marker not found")

with open(file_path, 'w', encoding='utf-8') as f:
    for i, line in enumerate(lines):
        if i not in ignore_indices:
            f.write(line)

print("Done v4.")
