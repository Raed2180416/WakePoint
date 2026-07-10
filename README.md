# GeoWake

GeoWake is a smart, location-based wake-up app that makes your daily commute stress-free.
Imagine never missing your stop again—whether you're taking the metro or driving—because GeoWake monitors your journey in real time and alerts you just before you reach your destination.

## What It Solves

- **Missed Stops**: Automatically alerts you when you're approaching your chosen stop, whether it's by distance or time.
- **Ease-of-Use**: Set your destination and preferred alert (like "wake me 2 minutes before I reach my stop") and let the app do the rest.
- **Accurate Tracking**: Uses a combination of on-device GPS and smart API calls to deliver accurate predictions—even if you lose connectivity underground.
- **Battery Efficiency**: GeoWake smartly adjusts its location update frequency based on your battery level, ensuring minimal drain while you travel.

## How It Works (In Brief)

1. **Destination & Settings**: Enter your destination via an intuitive search interface. Choose whether you want an alert based on time (minutes) or distance (kilometers).
2. **Real-Time Monitoring**: The app continuously tracks your location and compares it to your planned route.
3. **Smart Alerts**: When you're about to reach your stop, GeoWake sends you a local notification—no need to constantly check the map.
4. **Offline Reliability**: Even if you lose connection (like underground), the app uses cached route data and on-device computations to keep you informed.

GeoWake makes your commute easier by letting you enjoy your journey, without the hassle of waking up too early or missing your stop.

---

## OSM Deviation Simulation Dashboard

A web-based visual testing tool for simulating and debugging route deviation, rerouting, and alarm logic.

### Features

| Feature | Description |
|---------|-------------|
| **OSM Street Overlay** | Full Bengaluru street network rendered on Google Maps |
| **Deviation Simulation** | A* pathfinding simulates user deviating AWAY from current route |
| **Return Simulation** | A* pathfinding simulates user returning to original route |
| **Time Warp** | Slider 1x-500x accelerates ALL time-dependent logic uniformly |
| **Speed Control** | Simulated movement speed from 1-160 km/h |
| **Constraint Log Drawer** | Real-time slide-out panel showing deviation events, reroute decisions, termination evaluations |
| **Multi-Route Display** | Gray inactive routes, orange deviation path, colored active route |

### Running the Dashboard

```bash
# Build and serve for web
flutter run -d chrome --web-port=8080

# Or build release
flutter build web
```

Then open your browser to the dashboard URL.

### Dashboard Controls

| Control | Function |
|---------|----------|
| **Start Deviation** | Begin A* pathfinding away from current route |
| **Stop Deviation** | Halt deviation simulation at current position |
| **Go Back to Old Route** | Begin A* pathfinding back to original route |
| **Time Warp Slider** | Adjust time multiplier (1x = real-time, 500x = fast-forward) |
| **Speed Slider** | Adjust simulated GPS movement speed |
| **Constraint Drawer Toggle** | Show/hide the real-time event log panel |

### Time Warp Scope

Time warp affects **ALL** time-dependent logic uniformly:

- Deviation detection and sustain duration
- Reroute cooldown periods
- Alarm cooldown and firing intervals
- ETA calculations
- Termination policy duration checks
- GPS check intervals
- All logged timestamps

### Architecture

```
+-------------------------------------------------------------------------+
|                           WEB DASHBOARD                                 |
|  +-------------+  +-------------+  +-------------+  +----------------+  |
|  |  Controls   |  |  Map View   |  | Constraint  |  |  Time Warp     |  |
|  |  Panel      |  |  (GMaps +   |  | Log Drawer  |  |  Controls      |  |
|  |             |  |   OSM)      |  |             |  |                |  |
|  +-------------+  +-------------+  +-------------+  +----------------+  |
+-------------------------------------------------------------------------+
                             | WebSocket
                             v
+-------------------------------------------------------------------------+
|                      APP SERVICES (via AppClock)                        |
|   TrackingService -> RouteSessionManager -> DeviationMonitor            |
|                   -> ReroutePolicy -> TerminationPolicy                 |
+-------------------------------------------------------------------------+
```

### Key Components

| Component | File | Purpose |
|-----------|------|---------|
| `DeviationDashboard` | `lib/dashboard/deviation_dashboard.dart` | Main dashboard widget with map, controls, and drawer |
| `DeviationSimulationController` | `lib/dashboard/deviation_simulation_controller.dart` | Orchestrates deviation simulation, pathfinding, WebSocket |
| `OsmOverlayManager` | `lib/dashboard/osm_overlay_manager.dart` | Manages OSM street polylines on Google Maps |
| `OsmGraph` | `lib/services/testing/osm_graph.dart` | Graph data structure for OSM nodes/edges |
| `Pathfinder` | `lib/services/testing/pathfinder.dart` | A* pathfinding engine |
| `AppClock` | `lib/core/clock/app_clock.dart` | Time abstraction supporting time warp |

### OSM Data Pipeline

1. **Preprocessing**: `tools/osm_preprocessor.py` converts `.osm.pbf` to optimized binary
2. **Loading**: `OsmDataLoader` efficiently loads graph from binary format
3. **Pathfinding**: `Pathfinder` uses A* with highway-type cost multipliers

### Testing

```bash
# Run all tests (445 tests)
flutter test

# Run dashboard-specific tests
flutter test test/dashboard/

# Run with coverage
flutter test --coverage
```

### Implementation Details

See [docs/osm_dashboard_implementation.md](docs/osm_dashboard_implementation.md) for comprehensive implementation reference including:

- Codebase audits (DateTime.now, Timer locations)
- AppClock abstraction design
- File-by-file modification plans
- State machine designs
- Phase-by-phase implementation checklist

---

## Development Setup

### Prerequisites

- Flutter SDK (3.x)
- Dart SDK
- Google Maps API key (for map features)
- Chrome (for web dashboard testing)

### Running Tests

```bash
# All tests
flutter test

# With coverage
flutter test --coverage

# Specific test file
flutter test test/path/to/test_file.dart
```

### Building

```bash
# Android APK (debug)
flutter build apk --debug

# Web
flutter build web

# Run on device
flutter run
```

---

## Project Structure

```
lib/
  core/
    clock/          # AppClock time abstraction
    logging/        # Logging utilities
  dashboard/        # OSM deviation simulation dashboard
  models/           # Data models
  services/         # Core services (tracking, routing, etc.)
    testing/        # OSM graph and pathfinding
    tracking/       # GPS tracking and alarm logic
  widgets/          # Reusable UI components
test/
  core/             # Core utility tests
  dashboard/        # Dashboard-specific tests
  services/         # Service tests
docs/
  osm_dashboard_implementation.md  # Implementation reference
tools/
  osm_preprocessor.py  # OSM data preprocessing
```

---

## 🗺️ Codebase Map (`.wake/`)

The `.wake/` directory is WakePoint's **committed, deterministic map of itself** — a machine-and-human-readable snapshot of the repo's structure, symbols, call graphs, and feature intent. It exists so that AI coding agents (and new humans) can get accurate, grounded repo intelligence *without* re-deriving it live and hallucinating: every artifact is generated from the source tree, content-hashed, and pinned to a specific git commit. Think of it as a build output for "understanding the codebase," regenerated the same way you'd rebuild compiled assets.

### Artifact layout

| Path | What it holds |
| --- | --- |
| `.wake/map/` | Deterministic atomic map: `knowledge-graph.json`, `entry-points.json`, `change-impact.json`, `public-api-surface.json`, `module-interfaces.jsonl`, `type-signatures.jsonl`, and `LLM_NAVIGATION_GUIDE.md`. |
| `.wake/graph/` | Semantic reference/call graphs: `dart-symbol-graph.json`, `backend-call-graph.json`, and the raw `scip-dart.scip` index. |
| `.wake/rag/` | `codebase-index.json` — chunked, retrieval-ready index for RAG-style lookups. |
| `.wake/intent/` | Feature/intent graph (`intent-graph.json` + `.dot`/`.svg`) mapping code units to product features. |
| `.wake/MANIFEST.json` | The integrity root: every artifact's byte size, SHA-256, and `layer`, plus `gitCommit`/`gitTree`/`sourceDigest`/`rootDigest` provenance. |
| `.wake/AGENT_CONTEXT.md` | Human-readable entry point — the "read me first" orientation doc for agents working in the repo. |

### Deterministic vs. semantic layers

Each artifact is tagged with a `layer` in `MANIFEST.json`:

- **`deterministic`** — derived purely from the file tree via structural analysis (`map/`, `rag/`). Given the same git tree, these regenerate **byte-for-byte identical**; provenance anchors are a function of `HEAD` + tree, never wall-clock time.
- **`semantic`** — derived from deeper type/symbol resolution (`graph/`, `intent/`), sourced from the SCIP index. Richer, but dependent on a resolved SDK/toolchain.

This split lets tooling trust the deterministic layer as a stable contract while treating the semantic layer as best-effort enrichment.

### Regenerating the map

```bash
# 1. Deterministic atomic map + RAG index (fast, no toolchain needed)
node tools/wakepoint-indexer.mjs .

# 2. Semantic graphs (Dart symbol graph, backend call graph) from the SCIP index
node tools/wakepoint-decode-scip.mjs .

# 3. Feature/intent graph
node tools/wakepoint-build-intent-graph.mjs .

# 4. Re-seal the manifest (recomputes hashes + provenance)
node tools/wake-manifest.mjs
```

**Freshness check** (verifies artifacts match the current tree without rewriting them — use in CI or before trusting the map):

```bash
node tools/wake-manifest.mjs --check
```

A mismatch means the map is stale relative to `HEAD` and should be regenerated.

### Auto-update

The map is **regenerated automatically via a git hook**, so a normal commit keeps `.wake/` in sync with the code it describes — you rarely need to run the commands above by hand. Run them manually only when bootstrapping the hook, or when you want to inspect the map before committing.

### Provenance

The semantic layer is built from a **[SCIP](https://github.com/sourcegraph/scip) index produced by `scip-dart`** run against the project's pinned **Flutter SDK**. Because symbol resolution depends on the SDK, semantic artifacts carry the same commit/tree provenance in `MANIFEST.json` as the deterministic ones — so you can always tell which exact source state (and toolchain) a given map was generated from.

### One-command update

All layers regenerate through a single orchestrator:

```bash
node tools/wakepoint-update.mjs --fast      # deterministic map + intent graph + manifest (git-hook default)
node tools/wakepoint-update.mjs --semantic  # scip-dart + RAG + intent (slow; needs Flutter SDK)
node tools/wakepoint-update.mjs --all        # everything
node tools/wakepoint-update.mjs --check      # byte-reproducibility gate
```

A `pre-commit` hook runs `--fast` and stages `.wake/`; `post-commit`/`post-merge`/`post-checkout` flag `.wake/STALE` when the Dart source drifts from the last semantic build.

### MCP query layer (token-efficient)

`.mcp.json` registers **`codebase-memory`** ([DeusData/codebase-memory-mcp](https://github.com/DeusData/codebase-memory-mcp), MIT) — an additive graph the next agent queries directly (`search_code`, `query_graph`, `trace_path`, `get_architecture`, …) at a fraction of the tokens of reading files. It bootstraps from `.codebase-memory/graph.db.zst`. `scip-dart` (`.wake/graph/`) remains the Dart semantic **source of truth**; codebase-memory is heuristic/fast, not compiler-authoritative.


---

## License

Proprietary - All rights reserved.
