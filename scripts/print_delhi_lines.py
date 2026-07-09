import json

with open("d:/WakePoint/scripts/coverage_report.json", 'r', encoding='utf-8') as f:
    data = json.load(f)

lines = data['delhi'].get('lines', {})
print(f"{'LINE':<30} | {'COUNT':<10}")
print("-" * 45)
for line, count in sorted(lines.items(), key=lambda x: x[1], reverse=True):
    print(f"{line:<30} | {count:<10}")
