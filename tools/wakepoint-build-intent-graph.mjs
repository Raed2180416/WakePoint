#!/usr/bin/env node
/**
 * WakePoint hierarchical intent-graph builder.
 *
 * Joins the DETERMINISTIC structure (files + import edges from .wake/map, symbol-level
 * reference edges from .wake/graph/dart-symbol-graph.json) with the SEMANTIC feature
 * hierarchy (.wake/intent/features.json, LLM-authored). Every node/edge is tagged
 * deterministic:true|false and source:'map'|'scip'|'llm' so stale-structure vs
 * stale-intent is explicit. Emits intent-graph.json + a feature-level Graphviz SVG.
 *
 * Levels: repo -> feature -> file -> symbol.
 * Edges:  contains (structural) | depends-on (imports) | references (scip symbols).
 *
 * Usage: node tools/wakepoint-build-intent-graph.mjs [repoRoot]
 */
import { execFileSync } from 'node:child_process'
import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const repoRoot = path.resolve(process.argv[2] || path.join(path.dirname(fileURLToPath(import.meta.url)), '..'))
const mapPath = path.join(repoRoot, '.wake/map/knowledge-graph.json')
const symPath = path.join(repoRoot, '.wake/graph/dart-symbol-graph.json')
const featPath = path.join(repoRoot, '.wake/intent/features.json')
const outDir = path.join(repoRoot, '.wake/intent')
mkdirSync(outDir, { recursive: true })

function git(args, fb = '') { try { return execFileSync('git', args, { cwd: repoRoot, encoding: 'utf8' }).trim() } catch { return fb } }
const readJson = (p) => JSON.parse(readFileSync(p, 'utf8'))

const map = readJson(mapPath)
const sym = existsSync(symPath) ? readJson(symPath) : { fileDependencies: {} }

// Feature hierarchy: prefer the LLM-authored store, else derive deterministically from lib/ dirs.
let features, repoIntent, northStar, featuresDeterministic
if (existsSync(featPath)) {
  const f = readJson(featPath)
  features = f.features
  repoIntent = f.repoIntent
  northStar = f.northStar
  featuresDeterministic = false
} else {
  const dirs = {}
  for (const i of map.interfaces) {
    const parts = i.file.split('/')
    const key = parts[0] === 'lib' && parts.length > 2 ? `lib/${parts[1]}` : (parts[0] === 'geowake-server' ? 'geowake-server/src' : parts[0])
    ;(dirs[key] = dirs[key] || []).push(i.file)
  }
  features = Object.keys(dirs).sort().map(d => ({ id: d.replace(/[^\w]+/g, '-'), title: d, purpose: `Files under ${d} (structural fallback — run the semantic workflow for real intent).`, relatedPaths: [d], subfeatures: [] }))
  repoIntent = 'WakePoint — deterministic structural fallback (no semantic features.json present).'
  northStar = ''
  featuresDeterministic = true
}

// Assign each file to the feature with the longest matching relatedPath prefix.
function featureFor(file) {
  let best = null, bestLen = -1
  for (const ft of features) {
    for (const rp of (ft.relatedPaths || [])) {
      const norm = rp.replace(/\/$/, '')
      if ((file === norm || file.startsWith(norm + '/')) && norm.length > bestLen) { best = ft.id; bestLen = norm.length }
    }
  }
  return best
}

const nodes = []
const edges = []
const push = (n) => nodes.push(n)
const link = (from, to, type, deterministic, source, extra = {}) => edges.push({ from, to, type, deterministic, source, ...extra })

// repo node
push({ id: 'repo:WakePoint', level: 'repo', label: 'WakePoint', deterministic: false, source: 'llm', intent: repoIntent, northStar })

// feature nodes
const fileFeature = {}
for (const ft of features) {
  push({ id: `feature:${ft.id}`, level: 'feature', label: ft.title, deterministic: featuresDeterministic, source: featuresDeterministic ? 'map' : 'llm', purpose: ft.purpose, relatedPaths: ft.relatedPaths || [], keySymbols: ft.keySymbols || [] })
  link('repo:WakePoint', `feature:${ft.id}`, 'contains', featuresDeterministic, featuresDeterministic ? 'map' : 'llm')
  for (const sf of (ft.subfeatures || [])) {
    push({ id: `subfeature:${ft.id}:${sf.id}`, level: 'subfeature', label: sf.title, deterministic: false, source: 'llm', purpose: sf.purpose, relatedPaths: sf.relatedPaths || [] })
    link(`feature:${ft.id}`, `subfeature:${ft.id}:${sf.id}`, 'contains', false, 'llm')
  }
}

// file + symbol nodes (deterministic from the map)
const importersOf = {}
for (const e of map.dependencyEdges) importersOf[e.to] = (importersOf[e.to] || 0) + 1
for (const iface of map.interfaces) {
  const feat = featureFor(iface.file) || 'unassigned'
  fileFeature[iface.file] = feat
  push({ id: `file:${iface.file}`, level: 'file', label: iface.file, deterministic: true, source: 'map', role: iface.role, feature: feat, importers: importersOf[iface.file] || 0, exportCount: iface.exports.length })
  if (feat !== 'unassigned') link(`feature:${feat}`, `file:${iface.file}`, 'contains', false, 'llm')
  for (const ex of iface.exports.slice(0, 40)) {
    const sid = `symbol:${iface.file}#${ex.name}`
    push({ id: sid, level: 'symbol', label: ex.name, kind: ex.kind, deterministic: true, source: 'map', file: iface.file })
    link(`file:${iface.file}`, sid, 'contains', true, 'map')
  }
}

// depends-on edges (deterministic, from static imports)
for (const e of map.dependencyEdges) link(`file:${e.from}`, `file:${e.to}`, 'depends-on', true, 'map')
// references edges (deterministic from scip, symbol-precision) as file->file with weight
for (const [from, tos] of Object.entries(sym.fileDependencies || {})) for (const [to, w] of Object.entries(tos)) link(`file:${from}`, `file:${to}`, 'references', true, 'scip', { weight: w })

// aggregate feature->feature depends-on for the visual
const featEdge = {}
for (const e of map.dependencyEdges) {
  const a = fileFeature[e.from], b = fileFeature[e.to]
  if (a && b && a !== 'unassigned' && b !== 'unassigned' && a !== b) { const key = a + '	' + b; featEdge[key] = (featEdge[key] || 0) + 1 }
}

nodes.sort((a, b) => a.id.localeCompare(b.id))
edges.sort((a, b) => a.from.localeCompare(b.from) || a.to.localeCompare(b.to) || a.type.localeCompare(b.type))

const out = {
  schemaVersion: 'wakepoint-intent-graph-v1',
  gitCommit: git(['rev-parse', 'HEAD'], 'uncommitted'),
  generatedAt: git(['show', '-s', '--format=%cI', 'HEAD'], '1970-01-01T00:00:00+00:00'),
  structuralDigest: map.summary.gitTree,
  featuresSource: featuresDeterministic ? 'deterministic-fallback' : 'llm-authored',
  levels: ['repo', 'feature', 'subfeature', 'file', 'symbol'],
  summary: {
    repoIntent, northStar,
    featureCount: features.length,
    nodeCount: nodes.length,
    edgeCount: edges.length,
    byLevel: nodes.reduce((m, n) => (m[n.level] = (m[n.level] || 0) + 1, m), {}),
    byEdgeType: edges.reduce((m, e) => (m[e.type] = (m[e.type] || 0) + 1, m), {}),
  },
  nodes, edges,
}
writeFileSync(path.join(outDir, 'intent-graph.json'), JSON.stringify(out, null, 2))

// Feature-level Graphviz (readable; full detail stays in the JSON)
const esc = (s) => String(s).replace(/"/g, '\\"')
const dot = []
dot.push('digraph WakePoint {')
dot.push('  rankdir=LR; bgcolor="transparent"; node [shape=box style="rounded,filled" fillcolor="#eef4ff" fontname="Helvetica" fontsize=11]; edge [color="#8899bb" fontname="Helvetica" fontsize=8];')
dot.push(`  "WakePoint" [fillcolor="#1f6feb" fontcolor="white" shape=box3d];`)
for (const ft of features) {
  const n = map.interfaces.filter(i => fileFeature[i.file] === ft.id).length
  dot.push(`  "${esc(ft.id)}" [label="${esc(ft.title)}\\n(${n} files)"];`)
  dot.push(`  "WakePoint" -> "${esc(ft.id)}";`)
}
for (const [k, w] of Object.entries(featEdge).sort()) { const [a, b] = k.split('\t'); const pw = Math.min(6, 1 + Math.log2(w)).toFixed(2); dot.push(`  "${esc(a)}" -> "${esc(b)}" [penwidth=${pw} color="#cc7722"];`) }
dot.push('}')
const dotPath = path.join(outDir, 'intent-graph.dot')
writeFileSync(dotPath, dot.join('\n') + '\n')
try { execFileSync('dot', ['-Tsvg', dotPath, '-o', path.join(outDir, 'intent-graph.svg')]); } catch { console.log('(graphviz dot not available — .dot written, skip SVG)') }

console.log(`intent-graph: ${nodes.length} nodes, ${edges.length} edges, ${features.length} features (${out.featuresSource}); byLevel=${JSON.stringify(out.summary.byLevel)}`)
