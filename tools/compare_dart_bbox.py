import json, re, ssl, urllib.request
from pathlib import Path


def build_ssl_context(insecure: bool):
    if insecure:
        return ssl._create_unverified_context()
    try:
        import certifi

        return ssl.create_default_context(cafile=certifi.where())
    except Exception:
        return ssl.create_default_context()


def overpass_bbox(bbox, insecure=True, endpoint='https://overpass-api.de/api/interpreter', timeout_s=60):
    south, west, north, east = bbox
    query = (
        f"[out:json][timeout:{timeout_s}];"
        f"(nwr[public_transport=station][station~\"^(subway|metro|light_rail)$\"]({south},{west},{north},{east});"
        f"nwr[railway=station][station~\"^(subway|metro|light_rail)$\"]({south},{west},{north},{east});"
        f");out center;"
    )
    req = urllib.request.Request(
        endpoint,
        data=query.encode('utf-8'),
        headers={
            'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
            'User-Agent': 'WakePointStopAudit/1.0 (local audit script)',
        },
        method='POST',
    )
    ctx = build_ssl_context(insecure=insecure)
    with urllib.request.urlopen(req, timeout=timeout_s + 30, context=ctx) as resp:
        payload = json.loads(resp.read().decode('utf-8'))

    ids = set()
    for el in payload.get('elements', []):
        t = el.get('type')
        i = el.get('id')
        if t in ('node', 'way', 'relation') and i is not None:
            ids.add(f"{t}/{i}")
    return ids


def extract_field(block, key):
    m = re.search(rf"\"{re.escape(key)}\"\s*:\s*\"([^\"]*)\"", block)
    return m.group(1) if m else ''


def compare_city(city_key: str, bbox):
    text = Path('lib/all_india_stops.dart').read_text(encoding='utf-8')
    blocks = re.findall(r"\{\s*\"id\".*?\}\s*,", text, flags=re.S)

    snapshot = set()
    for b in blocks:
        if extract_field(b, 'city') != city_key:
            continue
        t = extract_field(b, 'osmType')
        oid = extract_field(b, 'osmId')
        if t and oid:
            snapshot.add(f"{t}/{int(oid)}")

    live = overpass_bbox(bbox, insecure=True)
    print(city_key, 'snapshotCount', len(snapshot))
    print(city_key, 'liveCount', len(live))
    print(city_key, 'missingInSnapshot', len(live - snapshot))
    print(city_key, 'extraInSnapshot', len(snapshot - live))


if __name__ == '__main__':
    # Chennai (small) bbox
    compare_city('chennai', (12.80, 80.05, 13.25, 80.35))
