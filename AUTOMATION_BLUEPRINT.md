# GeoWake — Zero-Cost AI Automation & Cost Elimination Blueprint

> **Verified July 23, 2026.** All tool versions, pricing, and capabilities checked against
> current releases, official docs, and real-world reports as of today.
> Budget constraint: $0/month. No workstation yet. Broke.

---

## PART 0: CORRECTIONS FROM PREVIOUS VERSION

My first blueprint had several errors. Here's what I got wrong and what's actually true:

| Claim (WRONG) | Reality (VERIFIED July 2026) |
|---|---|
| "Together AI $5 free credit" | **No free tier.** $5 minimum purchase required. Not free. |
| "OSRM Docker one-liner on ARM" | **No official ARM Docker image.** OSRM Docker is amd64-only. Must compile from source on ARM. |
| "Photon ~2-4GB RAM" | **Wrong.** Photon needs 16-32GB RAM for India data. Does NOT fit on 12GB Oracle VM. |
| "Nominatim ~4-8GB RAM" | **Underestimated.** India extract needs 8-16GB RAM for import, 4-8GB runtime. Tight on 12GB. |
| "Replace google_maps_flutter easily" | **18+ files use `google_maps_flutter.LatLng` as a data type** in business logic, not just rendering. This is a massive refactor, not a simple swap. |
| "Aider is actively maintained" | Latest release is **v0.86.0 from August 2025** — nearly a year old. Community is active but releases have stopped. |
| "SWE-agent for bug fixing" | Original SWE-agent is **deprecated**. Development moved to **mini-SWE-agent** (v2.4.5, July 6, 2026). |
| "Oracle VM: 4 OCPU, 24GB RAM" | **Halved in June 2026** to 2 OCPU, 12GB RAM. |
| "flutter_map + OSRM + Nominatim + Photon all fit on 12GB" | **They don't.** Photon and Nominatim for India-scale data need more RAM than available. Need a different strategy. |

---

## PART 1: CURRENT COST LEAKS — VERIFIED AUDIT

### What's Actually Costing You Money Right Now

| # | Cost Source | Monthly Cost | Evidence (file:line) | Status |
|---|---|---|---|---|
| 1 | Railway — Main API server | ~$5/mo | `lib/services/api_client.dart:11`, `lib/config/app_config.dart:17` | Always-on Hobby plan |
| 2 | Railway — Share backend | ~$1-2/mo | `lib/services/share/share_backend_config.dart:31` | Sleeps when idle |
| 3 | Google Maps Dynamic Maps SDK | $0 now → **$350+/mo at 1K DAU** | `pubspec.yaml` (`google_maps_flutter: ^2.2.5`), `lib/screens/maptracking.dart` | 10K free loads/mo (global), 70K (India) |
| 4 | Google Directions API | $0 now → **~$100/mo at 1K DAU** | `geowake-server/src/controllers/mapsController.js`, `lib/services/direction_service.dart:46` | 10K/70K free/mo |
| 5 | Google Places Autocomplete | $0 if session tokens work | `lib/services/places_service.dart:26-38` | **BUG: fake UUID** |
| 6 | Google Geocoding API | $0 | `geowake-server/src/controllers/mapsController.js:116` | 10K/70K free/mo |
| 7 | Google Nearby Search | $0 | `lib/services/metro_stop_service.dart:10` | 10K/70K free/mo |
| 8 | **LEAKED API KEY** | **Unlimited liability** | `android/app/build.gradle:41` comment | **ROTATE IMMEDIATELY** |

### What's Already Free (Verified — No Action Needed)

| Item | Evidence | Why Free |
|---|---|---|
| TelemetryService | `lib/services/telemetry/telemetry_service.dart` — HTTP sink defaults to `''` | Inert by default, local JSONL only |
| Push notifications | `pubspec.yaml` — `flutter_local_notifications` only, no FCM | Local, no server-side push |
| Database/storage | `pubspec.yaml` — Hive + SharedPreferences, server uses in-memory `node-cache` | No cloud DB |
| IAP (Play Billing) | `pubspec.yaml:50` — `in_app_purchase: ^3.3.0` | 15% of revenue only, no monthly fee |
| AdMob | `AndroidManifest.xml:38` — test ad IDs `ca-app-pub-3940256099942544/...` | Revenue source, not cost |
| Google Fonts | `pubspec.yaml:70` — `google_fonts: ^8.1.0` | Free API (but bundle locally for offline) |
| GitHub Actions CI | `.github/workflows/ci.yml` | 2,000 min/mo free for private repos |
| Qodana | `.github/workflows/qodana_code_quality.yml` | Starter tier = free |
| Patrol E2E | `pubspec.yaml:99` — `patrol: ^4.7.1` | Open-source, local devices |
| Crash monitoring | No Sentry/Bugsnag/Crashlytics in pubspec | Nothing deployed = $0 (but also no visibility) |

### Immediate Actions (Free, Do Today)

#### 1. ROTATE the leaked Google Maps API key
**File:** `android/app/build.gradle:41`
**Problem:** Comment contains `AIzaSyC0v...XHw0` — a live key committed to source control.
**Fix:** Google Cloud Console → APIs & Services → Credentials → delete old key → create new → restrict to Android app SHA-1 → put in `android/key.properties` (gitignored).
**Why:** Anyone with repo access can abuse the leaked key for unlimited billing.

#### 2. Fix Places session token bug
**File:** `lib/services/places_service.dart:26-38`
**Problem:** `_generateUuidV4()` uses `DateTime.now().microsecondsSinceEpoch` XOR — NOT a real UUID v4. Google may reject this as invalid session token, causing per-keystroke billing instead of free session billing.
**Fix:** The `uuid` package is already in `pubspec.yaml:57`. Replace the fake generator:
```dart
import 'package:uuid/uuid.dart';
// In _generateUuidV4():
String _generateUuidV4() {
  return const Uuid().v4();
}
```

#### 3. Remove dead `google_places_flutter` dependency
**File:** `pubspec.yaml:46`
**Problem:** `google_places_flutter: ^20.0.0` is listed but **NOT imported in any Dart file** (verified by grep — zero imports). It's dead weight.
**Fix:** Delete the line from pubspec.yaml. Zero risk.

#### 4. Bundle Google Fonts locally
**File:** `pubspec.yaml:70`
**Problem:** `google_fonts: ^8.1.0` fetches from `fonts.googleapis.com` at runtime — a network dependency on first use.
**Fix:** Download font files → put in `assets/fonts/` → set `GoogleFonts.config.allowRuntimeFetching = false`.

---

## PART 2: GOOGLE MAPS REPLACEMENT — DEEP ANALYSIS (NO QUALITY LOSS)

### The Critical Finding: LatLng Coupling

`google_maps_flutter.LatLng` is used as a **data type in 18+ files** — not just for map rendering. It's baked into business logic:

- `lib/services/trackingservice.dart` — core tracking orchestrator
- `lib/services/direction_service.dart` — route building
- `lib/services/snap_to_route.dart` — GPS snap-to-road
- `lib/services/deviation_detection.dart` — off-route detection
- `lib/services/active_route_manager.dart` — route management
- `lib/services/polyline_decoder.dart` — polyline parsing
- `lib/services/transfer_utils.dart` — transit transfer logic
- `lib/services/metro_stop_service.dart` — metro stop validation
- `lib/services/tracking/location_stream_handler.dart` — location processing
- `lib/dashboard/osm_overlay_manager.dart` — OSM street overlay
- `lib/services/testing/osm_graph.dart` — road network graph
- `lib/services/testing/osm_loader.dart` — binary OSM loader
- Plus 6 more screen/widget files

**Replacing `google_maps_flutter` entirely is a MASSIVE refactor**, not a simple swap. The `latlong2.LatLng` type used by `flutter_map` has identical fields (`.latitude`/`.longitude`) but is a different Dart type — every file would need updating.

### The Safe Strategy: Hybrid Approach (Zero Quality Loss)

**Keep `google_maps_flutter` for map rendering. Replace only the backend API calls.**

The app already separates rendering (Flutter client) from API calls (Node.js backend proxy). The client talks to your server via `ApiClient`, so the client doesn't know or care what routing engine the server uses.

| Google Service | Replacement | Quality Loss? | RAM on Oracle VM | Effort |
|---|---|---|---|---|
| **Map rendering** (Dynamic Maps SDK) | **Keep Google Maps** | None | N/A (client-side) | None |
| **Directions (car mode)** | **GraphHopper** (Java, ARM-native) | None — GraphHopper uses same OSM data | ~4-8GB | Medium (response adapter) |
| **Directions (transit mode)** | **Keep Google Directions for transit** OR use **OpenTripPlanner 2.9** with GTFS | None (if keeping Google) / Partial (OTP, city-dependent) | ~4-8GB (OTP) | Low (conditional in backend) / High (OTP setup) |
| **Places Autocomplete** | **Photon** OR keep Google (within free tier) | Moderate (Photon) / None (keep Google) | **16-32GB** (doesn't fit!) | N/A on Oracle VM |
| **Geocoding (reverse)** | **Nominatim** (self-hosted) OR public endpoint | Minimal — cosmetic label only, app falls back to "Dropped pin" | **8-16GB** (tight) | Low |
| **Nearby Search** | **Use already-bundled `all_india_stops.dart`** | **NONE — data is already in the app!** | 0 | Low (local spatial search) |

### Why OSRM is NOT the right choice for Oracle ARM VM

| Issue | Detail |
|---|---|
| No ARM Docker image | Official `osrm/osrm-backend` Docker is **amd64-only** (GitHub issue #6133 open since 2021) |
| Must compile from source | C++14 build on ARM — painful, slow, error-prone |
| India extract needs 32-64GB RAM to process | The `osrm-extract` + `osrm-contract` pipeline for full India PBF fails on 32GB RAM |
| Sub-region extracts work | Southern Zone (530MB) is manageable, but only covers South India |

### GraphHopper is the better choice (verified July 2026)

| Feature | GraphHopper | OSRM |
|---|---|---|
| ARM support | ✅ Java-based, runs anywhere JVM runs | ❌ No ARM Docker, compile from source |
| Transit routing | ✅ GTFS module (`reader-gtfs`) | ❌ No transit |
| License | Apache 2.0 (fully free) | MIT |
| India RAM (runtime) | ~4-8GB | ~3-4GB |
| India RAM (import) | ~16-32GB | 32-64GB (fails on 32GB!) |
| Docker ARM | Community images, or build your own | None |
| Turn-by-turn | ✅ | ✅ |
| Alternative routes | ✅ | ✅ |
| Real-time traffic | ❌ (static OSM speeds) | ❌ |
| Throughput | 1,000-3,000 q/s | 5,000-10,000 q/s |

### OpenTripPlanner 2.9 for transit (verified July 2026)

| Feature | Status |
|---|---|
| Latest version | v2.9.0 (March 2026), v2.10.0 in progress (July 2026 builds) |
| ARM Docker | ✅ Official multi-arch image: `opentripplanner/opentripplanner:2.10.0` |
| Transit support | ✅ Bus, metro, train, ferry via GTFS feeds |
| GTFS for India | Delhi (official: otd.delhi.gov.in), Bengaluru (github.com/Vonter/bmtc-gtfs), Mumbai (github.com/croyla/mumbai-gtfs) |
| RAM (runtime) | ~4-8GB per city region |
| RAM (graph build) | ~8-16GB per city |
| Actively maintained | ✅ 6-month release cadence, Java 25 support |

### Photon and Nominatim DON'T fit on 12GB Oracle VM for India

| Service | India RAM Required | Fits in 12GB? |
|---|---|---|
| Photon (Elasticsearch/OpenSearch) | 16-32GB | ❌ No |
| Nominatim (PostgreSQL + PostGIS) | 8-16GB import, 4-8GB runtime | ⚠️ Barely, and only if nothing else runs |
| Both together | 24-40GB | ❌ Absolutely not |

**Alternative for Places/Geocoding on Oracle VM:**
1. **Keep Google Places/Geocoding** — they're free within 70K calls/month (India pricing). At low DAU this costs $0.
2. **Use public Nominatim endpoint** — 1 req/s rate limit. For reverse geocoding only (low volume, cosmetic use case). Free, no self-hosting.
3. **Use Photon public demo** — photon.komoot.de has an API. Rate-limited but free for low volume.
4. **Defer self-hosting to workstation** — when the ₹12 lakh workstation arrives, run Photon + Nominatim there with full India data.

### Nearby Search: Already solved — use bundled data

The project already has `lib/services/testing/osm_graph.dart` and `assets/india_metro/india_metro_osm_stations.json` (869 deduplicated metro stations across India, fetched from Overpass API). `MetroStopService` can do a **local Haversine distance search** against `allIndiaStops` instead of calling Google Nearby Search.

**This eliminates the Nearby Search API call entirely with ZERO quality loss.** The data is already in the app.

### Recommended Migration Order (Lowest Risk First)

1. **Remove `google_places_flutter` from pubspec.yaml** — dead dependency, trivial
2. **Replace Nearby Search with local `all_india_stops.dart` spatial search** — data already bundled, zero quality loss
3. **Replace Google Geocoding (reverse) with public Nominatim endpoint** — cosmetic use case, app falls back gracefully
4. **Replace Google Directions (car mode) with GraphHopper** — highest cost saving, no quality loss for car routing
5. **Keep Google Directions for transit mode** (hybrid) — or invest in OTP2 + GTFS pipeline later
6. **Keep Google Places Autocomplete** — within free tier at low DAU; defer Photon to workstation
7. **Keep `google_maps_flutter` for rendering** — avoid the 18+ file refactor; Dynamic Maps cost only matters at high DAU

### What the Backend Architecture Looks Like After Migration

```
┌─────────────────────────────────────────────┐
│           Oracle Cloud ARM VM (12GB)          │
│                                               │
│  ┌─────────────┐  ┌──────────────────────┐   │
│  │ Express.js  │  │ GraphHopper (Java)    │   │
│  │ backend     │  │ Car/bike/foot routing │   │
│  │ (main API)  │  │ ~4-8GB RAM            │   │
│  └──────┬──────┘  └──────────────────────┘   │
│         │                                     │
│  ┌──────┴──────┐  ┌──────────────────────┐   │
│  │ Share backend│  │ OTP2 (optional)       │   │
│  │ (merged in)  │  │ Transit routing       │   │
│  │ ~128MB       │  │ ~4-8GB per city       │   │
│  └──────────────┘  └──────────────────────┘   │
│                                               │
│  ┌─────────────┐  ┌──────────────────────┐   │
│  │ Caddy       │  │ Uptime Kuma           │   │
│  │ reverse proxy│  │ Monitoring            │   │
│  │ + auto SSL   │  │ ~128MB                │   │
│  └─────────────┘  └──────────────────────┘   │
│                                               │
│  Total: ~6-10GB RAM used, 2-6GB free          │
│  (Room for Ollama 7B model if desired)        │
└─────────────────────────────────────────────┘
         │
         │ API calls proxied to:
         ▼
┌─────────────────────────────────────────────┐
│  Google Maps APIs (kept, within free tier)    │
│  • Dynamic Maps SDK (client-side rendering)   │
│  • Directions (transit mode only)             │
│  • Places Autocomplete (within 70K free/mo)   │
│  • Geocoding (fallback if Nominatim fails)    │
└─────────────────────────────────────────────┘
```

---

## PART 3: FREE AI AUTOMATION STACK — VERIFIED JULY 2026

### Tool Verification Status (All Checked July 22-23, 2026)

| Tool | Version (July 2026) | License | ARM? | Still Active? | Verified |
|---|---|---|---|---|---|
| **Ollama** | v0.32.1 (Jul 16) | MIT | ✅ arm64 binary | ✅ 177K stars, releases every few days | ✅ |
| **vLLM** | v0.25.1 (Jul 14) | Permissive | ❌ GPU-only, not for ARM CPU | ✅ 87K stars | ✅ (not viable on Oracle VM) |
| **llama.cpp** | b10091 (Jul 22) | MIT | ✅ arm64 pre-built binaries | ✅ 121K stars, daily builds | ✅ |
| **n8n** | v2.31.5 (Jul 22) | Sustainable Use (self-host free) | ✅ Node.js | ✅ 197K stars, MCP support confirmed | ✅ |
| **Open WebUI** | v0.10.2 (Jul 1) | Open WebUI License | ✅ | ✅ 146K stars, MCP plugins + automations | ✅ |
| **SigNoz** | v0.134.0 (Jul 22) | MIT + terms | ✅ Go + multi-arch Docker | ✅ 32K stars, needs 4GB min | ✅ |
| **Uptime Kuma** | v2.4.0 (May 31) | MIT | ✅ Node.js + SQLite | ✅ 89K stars, minimal requirements | ✅ |
| **PR-Agent** | v0.39.0 (Jul 5) | MIT | N/A (GitHub Action) | ✅ 12K stars, community-owned now | ✅ |
| **Mini-SWE-agent** | v2.4.5 (Jul 6) | MIT | ✅ Python + LiteLLM | ✅ 6K stars, supports Ollama, bash-only | ✅ |
| **Aider** | v0.86.0 (Aug 2025) | Apache-2.0 | ✅ Python | ⚠️ No releases in ~11 months, community active | ✅ (use with caution) |
| **Langfuse** | v3.224.0 (Jul 22) | MIT + EE | ✅ multi-arch Docker | ✅ 32K stars, needs 4-8GB min | ✅ |
| **codebase-memory MCP** | Active dev (1,643 commits) | Free/OSS | ✅ Go binary | ✅ 34K stars, single static binary | ✅ |

### LLM Strategy: Cloud APIs Now, Local Later

#### What fits on Oracle VM (verified)

With 12GB RAM total, ~2GB goes to OS, leaving **~10GB usable**:

| Model | Q4_K_M Size | Fits? | Speed on 2 OCPU | Use Case |
|---|---|---|---|---|
| Qwen3 Coder 7B | ~5.5GB | ✅ Comfortably | ~3-5 t/s | Fallback LLM, private code |
| Qwen2.5 7B | ~5GB | ✅ | ~3-5 t/s | General purpose fallback |
| Llama 3.1 8B | ~6GB | ✅ | ~2-4 t/s | General purpose |
| Qwen3 Coder 14B | ~10GB | ⚠️ Barely | ~2-3 t/s | Too tight, leaves no room |
| Anything 22B+ | ~13.5GB+ | ❌ | N/A | Does not fit |

**Verdict:** You CAN run a 7B model on Oracle VM, but at **3-5 tokens/second** it's painfully slow for code analysis. For comparison, free cloud APIs give you **300-1000+ t/s** with 70B+ models.

#### Free Cloud LLM API Tiers (VERIFIED July 2026)

| Provider | Model | Rate Limit | Speed | India? | Commercial? | Best For |
|---|---|---|---|---|---|---|
| **Google Gemini** | 2.5 Flash | 10 RPM, 250 req/day, 250K TPM | ~100 t/s | ✅ | ⚠️ (data may be used by Google on free tier) | Complex reasoning, 1M context |
| **Google Gemini** | 2.5 Flash-Lite | 15 RPM, 1,000 req/day | ~150 t/s | ✅ | ⚠️ | High-volume simple tasks |
| **Groq** | Llama 3.3 70B | 30 RPM, 1,000 req/day | **320-700+ t/s** | ✅ | ✅ | Fast agentic loops, code analysis |
| **Groq** | Llama 3.1 8B | 30 RPM, 14,400 req/day | **800+ t/s** | ✅ | ✅ | High-volume classification |
| **Cerebras** | Llama 3.3 70B | 30 RPM, 14,400 req/day, 1M TPD | **1000+ t/s** | ✅ | ✅ | Ultra-fast inference |
| **Mistral** | Codestral / Devstral 2 | 2 RPM, 1B tokens/month | ~100 t/s | ✅ | ⚠️ (data may be used for training) | Coding specialist |
| **OpenRouter** | 20+ free models | 20 RPM, 50 req/day | Varies | ✅ | ✅ | Model variety, fallback |
| **DeepSeek** | V3 / R1 | 5M free tokens (30 days), then $0.14/M | ~60 t/s | ✅ | ✅ | Cheapest after free tokens |
| **GitHub Models** | GPT-4o, Llama 3.3 70B | 10 RPM, 50 req/day (high tier) | Varies | ✅ | ⚠️ (prototyping only) | Testing frontier models |
| **Cloudflare AI** | Llama 3.3 70B | 10,000 neurons/day | ~50 t/s | ✅ | ✅ | Edge tasks (very limited) |
| **SambaNova** | DeepSeek V3.1 | 20 RPM, **20 req/day** | ~400 t/s | ✅ | ❌ (eval only) | Too restrictive |
| **Cohere** | Command R+ | 20 RPM, 1,000 req/month | ~100 t/s | ✅ | ❌ (eval only) | RAG-focused |

#### Recommended LLM Strategy

**Primary (now, no workstation):**
1. **Groq (Llama 3.3 70B)** — main "brain" for code analysis, bug fixing, agent reasoning. 320+ t/s, 1,000 req/day free. Use for complex tasks.
2. **Google Gemini 2.5 Flash** — 1M token context for whole-codebase analysis. 250 req/day free. Use when you need to feed entire files.
3. **Cerebras (Llama 3.3 70B)** — backup when Groq rate limit hit. 14,400 req/day. Same model, different provider.
4. **Groq (Llama 3.1 8B)** — high-volume simple tasks (log analysis, health checks, report generation). 14,400 req/day.

**Fallback (on Oracle VM):**
5. **Ollama + Qwen3 Coder 7B** — runs locally on Oracle VM at ~3-5 t/s. Use when all cloud rate limits are hit, or for private/sensitive code. Keeps VM above idle reclamation threshold.

**When workstation arrives:**
6. **Ollama + Qwen3 Coder 32B Q4_K_M** (~20GB VRAM on 2x RTX 3090) — primary, replaces all cloud APIs.
7. **Ollama + Qwen3 Coder 7B Q4_K_M** (~5.5GB) — fast secondary for simple tasks.

#### Can you run the LLM on Oracle VM 24/7?

**Yes, verified:**
- Oracle **explicitly promotes** running LLMs on Ampere A1 — they have blog posts, marketplace images, and partner with Ampere for llama.cpp optimization
- **Not against ToS** — only crypto mining, spam, and proxy/VPN exit nodes are banned
- **Idle reclamation safe** — a loaded model uses 30-50%+ RAM (above 20% threshold), inference hits 90-100% CPU (above 20% threshold)
- **Real-world confirmed** — multiple users report running Ollama on Oracle free tier without issues

**But it's slow:** 3-5 t/s on a 7B model with 2 OCPUs. Use it as fallback, not primary.

---

## PART 4: THE COMPLETE AUTOMATION ARCHITECTURE

### Architecture Diagram (Verified Stack)

```
┌────────────────────────────────────────────────────────────────┐
│                    ORACLE CLOUD FREE TIER                       │
│              Hyderabad (ap-hyderabad-1) · 2 OCPU · 12GB         │
│                                                                │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌───────────────────┐ │
│  │ Express  │ │ Graph    │ │ OTP2     │ │ Uptime Kuma       │ │
│  │ .js API  │ │ Hopper   │ │ (transit │ │ (monitoring)      │ │
│  │ + Share  │ │ (routing)│ │  optional│ │ ~128MB            │ │
│  │ backend  │ │ ~4-8GB   │ │ ~4-8GB)  │ │                   │ │
│  │ ~640MB   │ │          │ │          │ │                   │ │
│  └────┬─────┘ └──────────┘ └──────────┘ └────────┬──────────┘ │
│       │                                              │          │
│  ┌────┴─────────────────────────────────────────────┴──────┐  │
│  │              n8n (orchestrator, ~1-2GB)                   │  │
│  │  • Health check workflows (every 5 min)                  │  │
│  │  • CI failure → LLM analysis → GitHub issue              │  │
│  │  • Weekly report generator                                │  │
│  │  • API quota monitor                                      │  │
│  │  • Auto-fix trigger (new bug issue → SWE-agent)          │  │
│  └────┬────────────────────────────────────────────────────┘  │
│       │                                                        │
│  ┌────┴────────────────────────────────────────────────────┐  │
│  │  Ollama + Qwen3 Coder 7B (~5.5GB) — fallback LLM        │  │
│  │  Used when cloud API rate limits are hit                  │  │
│  └─────────────────────────────────────────────────────────┘  │
│                                                                │
│  Total RAM: ~10-12GB (tight but fits)                         │
│  Caddy reverse proxy + auto-SSL on top                        │
└──────────────────────────┬─────────────────────────────────────┘
                           │
            LLM API calls (primary brain)
                           │
                           ▼
┌────────────────────────────────────────────────────────────────┐
│              FREE CLOUD LLM APIs (rotation)                     │
│                                                                │
│  Groq (Llama 3.3 70B, 320+ t/s)  ── primary, code analysis    │
│  Gemini 2.5 Flash (1M context)   ── whole-file analysis       │
│  Cerebras (Llama 3.3 70B)        ── backup when Groq limited   │
│  Groq (Llama 3.1 8B, 800+ t/s)  ── high-volume simple tasks   │
└────────────────────────────────────────────────────────────────┘
                           │
              Agent actions via MCP
                           │
                           ▼
┌────────────────────────────────────────────────────────────────┐
│              MCP SERVER LAYER (on Oracle VM)                    │
│                                                                │
│  • @modelcontextprotocol/server-filesystem  (file ops)         │
│  • @modelcontextprotocol/server-git          (repo ops)        │
│  • github/github-mcp-server (31.6K stars)   (GitHub API)       │
│  • @modelcontextprotocol/server-memory       (persistent KB)   │
│  • @modelcontextprotocol/server-sqlite       (DB queries)      │
│  • @playwright/mcp                           (browser testing) │
│  • codebase-memory-mcp (34K stars, Go binary) (code intel)    │
│  • Context7                                  (current docs)    │
└────────────────────────────────────────────────────────────────┘
                           │
              GitHub Actions CI/CD
                           │
                           ▼
┌────────────────────────────────────────────────────────────────┐
│              GITHUB (free tier)                                 │
│                                                                │
│  • GitHub Actions CI (2000 min/mo free)                        │
│  • PR-Agent v0.39.0 (AI code review, MIT, self-hosted)        │
│  • Dependabot (auto dependency updates)                        │
│  • Gitleaks (secret scanning on every PR)                      │
│  • Semgrep (SAST for Dart/JS/TS)                               │
│  • CodeQL (semantic security analysis)                         │
│  • Mini-SWE-agent v2.4.5 (auto bug fix via bash, LiteLLM)     │
└────────────────────────────────────────────────────────────────┘
                           │
              When workstation arrives
                           │
                           ▼
┌────────────────────────────────────────────────────────────────┐
│              WORKSTATION (₹12 LAKH, 2x RTX 3090 = 48GB VRAM)   │
│                                                                │
│  • Ollama + Qwen3 Coder 32B Q4_K_M (~20GB) — primary brain    │
│  • Ollama + Qwen3 Coder 7B Q4_K_M (~5.5GB) — fast secondary   │
│  • Open WebUI v0.10.2 (AI ops dashboard, MCP plugins)         │
│  • SigNoz v0.134.0 (APM + logs + traces, ~4GB)                │
│  • Langfuse v3.224.0 (LLM observability, ~4-8GB)              │
│  • Photon + Nominatim (full India geocoding, ~32GB)           │
│  • All MCP servers relocate here from Oracle VM               │
│  • n8n relocates here (faster, more RAM for workflows)        │
└────────────────────────────────────────────────────────────────┘
```

### The Automated Loop (24/7)

```
                    ┌──────────────────────┐
                    │   SOMETHING HAPPENS   │
                    └──────────┬───────────┘
                               │
                    ┌──────────▼───────────┐
                    │   DETECTION LAYER     │
                    │                       │
                    │ • Uptime Kuma: backend │
                    │   down or slow        │
                    │ • GitHub Actions: CI  │
                    │   test failure        │
                    │ • Dependabot: vuln    │
                    │   found in dependency │
                    │ • Gitleaks: secret    │
                    │   leaked in commit    │
                    │ • n8n scheduled: API  │
                    │   quota at 80%        │
                    │ • n8n scheduled:      │
                    │   nightly test suite  │
                    └──────────┬───────────┘
                               │
                    ┌──────────▼───────────┐
                    │   ANALYSIS LAYER      │
                    │                       │
                    │ • n8n receives event  │
                    │   via webhook/schedule│
                    │ • Sends context to    │
                    │   Groq (Llama 3.3 70B)│
                    │   or Gemini 2.5 Flash │
                    │ • Agent reads code    │
                    │   via codebase-memory │
                    │   MCP (34K stars, Go) │
                    │ • Agent fetches docs  │
                    │   via Context7 MCP    │
                    │ • If cloud rate-limited│
                    │   → fallback to local │
                    │   Ollama Qwen3 7B     │
                    └──────────┬───────────┘
                               │
                    ┌──────────▼───────────┐
                    │   FIXING LAYER        │
                    │                       │
                    │ • Mini-SWE-agent       │
                    │   v2.4.5 (MIT, bash-  │
                    │   only, works with    │
                    │   ANY model via       │
                    │   LiteLLM)            │
                    │ • Writes patch        │
                    │ • Runs flutter test   │
                    │ • Runs flutter analyze│
                    │ • If tests pass →     │
                    │   creates GitHub PR   │
                    │ • If tests fail →     │
                    │   iterates (max 3x)   │
                    └──────────┬───────────┘
                               │
                    ┌──────────▼───────────┐
                    │   VALIDATION LAYER    │
                    │                       │
                    │ • PR-Agent v0.39.0    │
                    │   (MIT, community-    │
                    │   owned, AI review)   │
                    │ • Semgrep: SAST scan  │
                    │ • Gitleaks: secret    │
                    │   scan                │
                    │ • GitHub Actions:     │
                    │   full CI suite       │
                    │   (1373+ tests)       │
                    │ • Never-late replay   │
                    │   harness MUST pass   │
                    │ • CodeQL: semantic    │
                    │   security analysis   │
                    └──────────┬───────────┘
                               │
                    ┌──────────▼───────────┐
                    │   NOTIFICATION LAYER  │
                    │                       │
                    │ • n8n → Telegram/     │
                    │   Discord alert with  │
                    │   summary             │
                    │ • Open WebUI shows    │
                    │   agent trace         │
                    │ • All events logged   │
                    └──────────┬───────────┘
                               │
                    ┌──────────▼───────────┐
                    │  HUMAN APPROVAL GATE  │
                    │                       │
                    │ • You review the PR   │
                    │   on your phone       │
                    │ • Merge or reject     │
                    │ • Agent NEVER deploys │
                    │   directly            │
                    │ • Critical invariants │
                    │   protected (see below)│
                    └──────────────────────┘
```

### Critical Invariant Protection

The AI agent must NEVER autonomously change these (from AGENTS.md):

1. **Core alarm is always free** — never gate `canUseCoreAlarm`, `canUseBasicReliability`, `canUseBackstopAlarm`, `canUseSingleActiveRoute` behind Pro
2. **Never-late guarantee** — replay harness test is a hard CI gate
3. **Consent is default-OFF** — mobility data sharing requires explicit opt-in
4. **Fail-open for Pro features** — Pro feature failure must never affect core alarm
5. **No snooze** — a wake alarm must never be delayable

**Implementation:** Add custom Semgrep rules that flag any PR touching these files/patterns for mandatory human review:
- `lib/services/monetization/premium_service.dart` — feature gate logic
- `test/ekf/replay_harness_test.dart` — never-late test
- `lib/services/data_asset/mobility_consent_service.dart` — consent logic
- Any file containing `canUseCoreAlarm`, `canUseBackstopAlarm`, `canUseSingleActiveRoute`

---

## PART 5: STEP-BY-STEP IMPLEMENTATION PLAN

### Phase 1: This Week (Zero Cost, Zero Hardware)

| # | Task | Time | Cost |
|---|---|---|---|
| 1 | Rotate leaked Google Maps API key | 10 min | $0 |
| 2 | Fix Places session token bug (use real uuid package) | 15 min | $0 |
| 3 | Remove dead `google_places_flutter` from pubspec.yaml | 2 min | $0 |
| 4 | Bundle Google Fonts locally | 30 min | $0 |
| 5 | Sign up Oracle Cloud — select **Hyderabad** home region | 20 min | $0 |
| 6 | Upgrade Oracle account to **Pay As You Go** (priority ARM allocation, stays $0) | 10 min | $0 |
| 7 | Set $1 budget alert in Oracle Cost Management | 5 min | $0 |
| 8 | Create ARM VM (2 OCPU, 12GB, 47GB+ boot volume, Ubuntu 24.04) | 15 min | $0 |
| 9 | Install Docker + Docker Compose on VM | 10 min | $0 |
| 10 | Deploy Uptime Kuma (Docker one-liner) | 5 min | $0 |
| 11 | Add Dependabot config (`.github/dependabot.yml`) | 5 min | $0 |
| 12 | Add Gitleaks + Semgrep to CI workflow | 20 min | $0 |
| 13 | Sign up for Groq, Google Gemini, Cerebras free API keys | 15 min | $0 |
| 14 | Set up free Discord/Telegram bot for alerts | 15 min | $0 |

### Phase 2: Next 2 Weeks (Still Zero Cost)

| # | Task | Details |
|---|---|---|
| 15 | Deploy Express.js backend on Oracle VM | Docker, PM2, Caddy reverse proxy with auto-SSL |
| 16 | Merge Share backend into main Express server | Save resources, one process |
| 17 | Deploy GraphHopper on Oracle VM | Download India sub-region extract (Southern Zone 530MB to start), import, run |
| 18 | Replace Google Directions (car mode) with GraphHopper | Response adapter in backend: GraphHopper JSON → Google Directions JSON format |
| 19 | Replace Google Nearby Search with local `all_india_stops.dart` search | Haversine distance filter against bundled 869 stations |
| 20 | Replace Google Geocoding with public Nominatim endpoint | Low-volume reverse geocoding only, 1 req/s is fine |
| 21 | Deploy n8n on Oracle VM | Docker, connect to Telegram/Discord webhook |
| 22 | Create n8n workflows | Health check (5 min), CI failure → LLM analysis, weekly report, API quota monitor |
| 23 | Deploy PR-Agent as GitHub Action | Uses Groq API for LLM, reviews every PR |
| 24 | Deploy Ollama + Qwen3 Coder 7B on Oracle VM | Fallback LLM, keeps VM above idle reclamation |
| 25 | Install codebase-memory MCP on Oracle VM | Index the GeoWake repo for agent code intelligence |

### Phase 3: Next Month (Still Zero Cost)

| # | Task | Details |
|---|---|---|
| 26 | Set up Mini-SWE-agent | Docker, configure LiteLLM to use Groq primary + Ollama fallback |
| 27 | Create auto-fix workflow | n8n: new "bug" labeled issue → SWE-agent → PR → PR-Agent review → notify |
| 28 | Set up nightly test suite | n8n scheduled: trigger GitHub Actions self-hosted runner → `flutter test` |
| 29 | Add custom Semgrep rules for invariant protection | Flag PRs touching premium_service.dart, consent service, replay harness |
| 30 | Deploy Sentry (free cloud tier) for Flutter app | 5,000 errors/month free, add SDK to app |
| 31 | Optionally deploy OTP2 for transit routing | Only if GTFS available for target cities (Delhi, Bengaluru, Mumbai) |
| 32 | Set up GitHub Actions self-hosted runner on Oracle VM | Saves GitHub Actions minutes, faster CI |

### Phase 4: When Workstation Arrives

| # | Task | Details |
|---|---|---|
| 33 | Install Ubuntu Server 24.04 LTS (headless) | SSH-only, no GUI |
| 34 | Install Docker + Docker Compose | |
| 35 | Install Ollama with Qwen3 Coder 32B + 7B | Primary LLM brain, replaces all cloud APIs |
| 36 | Install Open WebUI | AI ops dashboard, MCP plugins, automations |
| 37 | Configure MCP servers | Filesystem, Git, GitHub, Memory, Playwright, Context7, codebase-memory |
| 38 | Install SigNoz | Full APM (logs + metrics + traces), ~4GB RAM |
| 39 | Install Langfuse | LLM observability, trace agent runs, ~4-8GB RAM |
| 40 | Install Photon + Nominatim | Full India geocoding/autocomplete, ~32GB RAM |
| 41 | Repoint n8n from cloud APIs to local Ollama | Cloud APIs become fallback instead of primary |
| 42 | Relocate heavy services from Oracle VM to workstation | SigNoz, Langfuse, Photon, Nominatim, MCP servers |

### Ongoing Automated Schedule

| Frequency | What Runs | How |
|---|---|---|
| Every 5 min | Backend health check | n8n → HTTP ping → alert if down |
| Every 15 min | API quota check | n8n → Google Cloud API → alert at 80% free tier |
| Every hour | Log anomaly scan | n8n → Ollama/Groq → anomaly detection → alert |
| Every 6 hours | Dependency vulnerability scan | n8n → GitHub Actions → Dependabot + Trivy |
| Daily 2 AM | Full test suite | n8n → self-hosted runner → `flutter test` (1373+ tests) |
| Daily 8 AM | Error rate report | n8n → Sentry API → Groq summary → Telegram |
| Weekly Sunday | Comprehensive ops report | n8n → gather all metrics → Groq generates markdown |
| On new "bug" issue | Auto-fix attempt | n8n → Mini-SWE-agent → PR → PR-Agent review → notify |
| On new PR | AI code review | PR-Agent GitHub Action → review + security scan |
| On CI failure | Auto-analysis | n8n webhook → Groq → issue with diagnosis |
| On secret leak | Urgent alert | Gitleaks → n8n → immediate Telegram alert |

---

## PART 6: RELIABILITY ANALYSIS — WHAT COULD BITE YOU

### Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Oracle cancels free tier | Very low (core strategy) | High | Backup: Fly.io free tier, Render free tier. Keep Docker Compose configs portable. |
| Oracle halves limits again | Low (already halved once) | Medium | Current stack fits in 12GB. If halved to 6GB, move Ollama + n8n to workstation early. |
| Oracle reclaims idle VM | Very low (LLM keeps it active) | High | Run Ollama with model loaded = 30-50% RAM usage. Schedule n8n health checks every 5 min. |
| Groq discontinues free tier | Low-Medium | Medium | Cerebras + Gemini as backup. Local Ollama as ultimate fallback. |
| Gemini free tier data privacy | Certain (already happening) | Low | Don't send API keys or secrets to cloud LLMs. Use local Ollama for sensitive code. Upgrade to paid Gemini ($0) for data privacy. |
| GraphHopper routing quality < Google | Low for car | Low | Keep Google Directions as fallback. Conditional routing: try GraphHopper first, fall back to Google if it fails. |
| GTFS data stale/outdated | Medium (community-maintained) | Medium | Keep Google Directions for transit as primary. OTP2 is enhancement, not replacement. |
| Mini-SWE-agent makes bad fix | Medium | Low | Human approval gate. PR-Agent review. Full CI suite (1373+ tests) must pass. Never-late replay harness is hard gate. |
| Agent hallucinates and deletes code | Low | Medium | Git history is recoverable. SWE-agent works in branches. PRs are reviewed before merge. |
| API key leak in PR | Low (Gitleaks scans) | High | Gitleaks in CI scans every PR. MCP filesystem agent can't commit directly. |
| Workstation hardware failure | Low | Medium | UPS for power. Regular backups to Oracle Object Storage (20GB free). Git is code backup. |
| n8n license change | Low (Sustainable Use License is stable) | Medium | Activepieces (MIT) as drop-in replacement. Workflows are portable JSON. |
| Aider abandoned (no releases in 11 months) | Medium | Low | Use Mini-SWE-agent as primary coding agent instead. Aider is optional, not critical path. |

### What Makes This Robust

1. **Defense in depth** — every critical function has a fallback:
   - LLM: Groq → Cerebras → Gemini → local Ollama
   - Routing: GraphHopper → Google Directions (fallback)
   - Geocoding: Nominatim → Google Geocoding (fallback)
   - Monitoring: Uptime Kuma → GitHub Actions CI → Sentry
   - Hosting: Oracle VM → Fly.io → Render (portable Docker configs)

2. **Human approval gate** — the agent NEVER deploys directly. It creates PRs. You approve. This protects all critical invariants.

3. **Hard CI gates** — even if the agent creates a PR, it must pass:
   - `flutter analyze lib/ --no-fatal-infos` (0 errors required)
   - `flutter test` (all 1373+ tests)
   - Never-late replay harness (`test/ekf/replay_harness_test.dart`)
   - Reachability tests (`test/reachability/`)
   - Scale tests (`test/scale/reachability_scale_test.dart`)
   - Semgrep security scan
   - Gitleaks secret scan
   - PR-Agent AI review

4. **Portable architecture** — everything runs in Docker containers with Docker Compose configs. If Oracle VM dies, you can redeploy on any Linux machine in minutes.

5. **No vendor lock-in** — all tools are open source or have open-source alternatives:
   - n8n → Activepieces (MIT)
   - Ollama → llama.cpp (MIT)
   - Open WebUI → any chat interface
   - SigNoz → Prometheus + Grafana + Loki

---

## PART 7: COST SUMMARY

### Before (Current State)
| Item | Monthly Cost |
|---|---|
| Railway main server | $5 (~₹420) |
| Railway share backend | $1-2 (~₹85-170) |
| Google Maps APIs (at scale) | $0-500+ (~₹0-42,000+) |
| **Total** | **$6-507+/mo** |

### After (Fully Automated)
| Item | Monthly Cost |
|---|---|
| Oracle Cloud ARM VM (2 OCPU, 12GB) | $0 (Always Free, PAYG) |
| GraphHopper (self-hosted routing) | $0 |
| Uptime Kuma (self-hosted monitoring) | $0 |
| n8n (self-hosted orchestration) | $0 |
| Ollama + Qwen3 Coder 7B (fallback LLM) | $0 |
| All MCP servers | $0 |
| Groq + Gemini + Cerebras (cloud LLM APIs) | $0 (free tiers) |
| GitHub Actions CI | $0 (free tier) |
| Sentry (error tracking) | $0 (free tier) |
| Cloudflare R2 (if used for PMTiles) | $0 (10GB free, zero egress) |
| **Total** | **$0/month** |

### When Workstation Arrives
| Item | Monthly Cost |
|---|---|
| Electricity (600-800W under load, 24/7) | ~₹3,500-5,000 (~$42-60) |
| Everything else | $0 |
| **Total** | **~₹3,500-5,000/month (electricity only)** |

### One-Time Costs
| Item | Cost | When |
|---|---|---|
| Workstation (2x used RTX 3090 + components) | ~₹9,00,000 | 1-2 months |
| UPS 3KVA | ~₹50,000 | With workstation |
| Oracle Cloud signup | $0 | This week |
| All software | $0 | Forever |

---

## PART 8: QUICK REFERENCE — ALL VERIFIED FREE TOOLS

### LLM Runtimes (verified July 2026)
- **Ollama** v0.32.1 (MIT, 177K stars) — https://ollama.com — ARM arm64 binary available
- **llama.cpp** b10091 (MIT, 121K stars) — https://github.com/ggml-org/llama.cpp — ARM pre-built binaries
- vLLM v0.25.1 — NOT viable on ARM CPU (GPU-only, skip for Oracle VM)

### LLM Models (verified July 2026)
- **Qwen3 Coder 7B** (Apache-2.0, ~5.5GB Q4) — best coding model for Oracle VM
- **Qwen3 Coder 32B** (Apache-2.0, ~20GB Q4) — best for workstation
- **Qwen3.6-27B** (Apache-2.0, ~17GB Q4) — alternative for workstation

### Free Cloud LLM APIs (verified July 2026)
- **Groq** — https://console.groq.com — 30 RPM, 1,000 RPD (70B), 14,400 RPD (8B), 320+ t/s
- **Google Gemini** — https://ai.google.dev — 10-15 RPM, 250-1,000 RPD, 1M context
- **Cerebras** — https://cloud.cerebras.ai — 30 RPM, 14,400 RPD, 1M TPD, 1000+ t/s
- **Mistral** — https://console.mistral.ai — 2 RPM, 1B tokens/month, Codestral for coding
- **OpenRouter** — https://openrouter.ai — 20+ free models, 50 RPD

### Agent & Coding Tools (verified July 2026)
- **Mini-SWE-agent** v2.4.5 (MIT, 6K stars) — https://github.com/SWE-agent/mini-swe-agent — supports Ollama via LiteLLM, bash-only, 74% SWE-bench
- **Aider** v0.86.0 (Apache-2.0, 48K stars) — https://github.com/Aider-AI/aider — Ollama support, Dart support, but no releases in 11 months
- **PR-Agent** v0.39.0 (MIT, 12K stars) — https://github.com/The-PR-Agent/pr-agent — community-owned, GitHub Action

### Orchestration & Automation (verified July 2026)
- **n8n** v2.31.5 (197K stars) — https://github.com/n8n-io/n8n — MCP support confirmed, AI agents, 1500+ integrations
- **Open WebUI** v0.10.2 (146K stars) — https://github.com/open-webui/open-webui — MCP plugins, automations, calendar scheduling
- **Activepieces** (MIT, 23K stars) — https://github.com/activepieces/activepieces — n8n alternative if license changes

### MCP Servers (all verified free, no account needed)
- `npx @modelcontextprotocol/server-filesystem` — file operations
- `npx @modelcontextprotocol/server-git` — git operations
- `github/github-mcp-server` (31.6K stars) — GitHub API (free GitHub account, 5000 req/hr)
- `npx @modelcontextprotocol/server-memory` — persistent knowledge graph
- `npx @modelcontextprotocol/server-sqlite` — SQLite queries
- `npx @playwright/mcp` — browser automation
- `npx @upstash/context7-mcp` — current library docs
- **codebase-memory-mcp** (34K stars, Go binary) — code intelligence, 158 languages

### Monitoring & Observability (verified July 2026)
- **SigNoz** v0.134.0 (MIT, 32K stars) — https://github.com/SigNoz/signoz — 4GB min, multi-arch Docker
- **Uptime Kuma** v2.4.0 (MIT, 89K stars) — https://github.com/louislam/uptime-kuma — minimal requirements, ARM
- **Langfuse** v3.224.0 (MIT, 32K stars) — https://github.com/langfuse/langfuse — 4-8GB min, LLM observability
- **Sentry** (free cloud tier) — 5,000 errors/month, 1 project

### Map/Routing Replacements (verified July 2026)
- **GraphHopper** (Apache-2.0) — https://github.com/graphhopper/graphhopper — Java, ARM, GTFS transit support
- **OpenTripPlanner** v2.9.0 (LGPL) — https://github.com/opentripplanner/OpenTripPlanner — ARM Docker, transit with GTFS
- **Nominatim** (GPL) — public endpoint: https://nominatim.openstreetmap.org (1 req/s) or self-host
- **Photon** v1.2.1 (Apache-2.0) — https://github.com/komoot/photon — public demo: photon.komoot.de, or self-host (needs 16-32GB)
- **Protomaps PMTiles** — https://docs.protomaps.com — Cloudflare R2 hosting, `flutter_map_pmtiles` package
- **Overpass API** — public endpoints for transit stop queries

### Security (all free)
- **Semgrep** (community) — https://github.com/semgrep/semgrep — SAST for Dart/JS/TS
- **Gitleaks** (MIT) — https://github.com/gitleaks/gitleaks — secret scanning
- **Trivy** (Apache-2.0) — https://github.com/aquasecurity/trivy — container/IaC scanning
- **GitHub CodeQL** — free for public repos, semantic security analysis

### Infrastructure (free hosting)
- **Oracle Cloud Always-Free** — https://www.oracle.com/cloud/free/ — 2 OCPU, 12GB RAM, Hyderabad region
- **Cloudflare R2** — 10GB free, zero egress — for PMTiles hosting
- **GitHub Actions** — 2,000 min/mo free for private repos
