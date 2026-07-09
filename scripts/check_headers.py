
path = "d:/WakePoint/lib/all_india_stops.dart"
with open(path, 'r', encoding='utf-8') as f:
    for i, line in enumerate(f):
        if "---" in line:
            print(f"{i+1}: {line.strip()}")
