#!/usr/bin/env node
/**
 * WakePoint map manifest — the single freshness + reproducibility oracle.
 *
 * Walks .wake/, computes a normalized sha256 per artifact (volatile fields nulled,
 * keys sorted, so the digest reflects CONTENT not wall-clock), tags each artifact
 * deterministic|semantic, records the tracked-source fingerprint (sourceDigest),
 * and emits .wake/MANIFEST.json with a top-level rootDigest.
 *
 *   node tools/wake-manifest.mjs --write   # (re)build MANIFEST.json
 *   node tools/wake-manifest.mjs --check    # recompute + assert byte-equality; exit 1 on drift
 *
 * --check is a CI/hook gate: regenerate the deterministic layers, run --check, and any
 * unreproducible drift fails. It also reports which SEMANTIC artifacts are stale
 * (built against an older sourceDigest than the current tree).
 */
import { execFileSync } from 'node:child_process'
import { readdirSync, readFileSync, writeFileSync, statSync } from 'node:fs'
import crypto from 'node:crypto'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const repoRoot = path.resolve(process.env.WAKE_REPO_ROOT || path.join(path.dirname(fileURLToPath(import.meta.url)), '..'))
const wakeDir = path.join(repoRoot, '.wake')
const manifestPath = path.join(wakeDir, 'MANIFEST.json')
const mode = process.argv.includes('--check') ? 'check' : 'write'

function git(args, fb = '') { try { return execFileSync('git', args, { cwd: repoRoot, encoding: 'utf8' }) } catch { return fb } }
function sha256(buf) { return crypto.createHash('sha256').update(buf).digest('hex') }

const VOLATILE = new Set(['generatedAt', 'updatedAt', 'timestamp', 'startedAt', 'finishedAt', 'durationMs', 'builtAt', 'builtAgainstTree'])
function canonical(v) {
  if (Array.isArray(v)) return v.map(canonical)
  if (v && typeof v === 'object') {
    const out = {}
    for (const k of Object.keys(v).sort()) out[k] = VOLATILE.has(k) ? null : canonical(v[k])
    return out
  }
  return v
}

// Deterministic fingerprint of all tracked source (mode + blob sha + path per file).
function sourceDigest() { return sha256(git(['ls-files', '-s'], '')) }

function walk(dir, acc = []) {
  for (const name of readdirSync(dir).sort()) {
    const abs = path.join(dir, name)
    const rel = path.relative(wakeDir, abs)
    if (rel === 'MANIFEST.json' || rel === 'STALE') continue
    const st = statSync(abs)
    if (st.isDirectory()) walk(abs, acc)
    else acc.push({ abs, rel, bytes: st.size })
  }
  return acc
}

function layerOf(rel) {
  if (rel.startsWith('map/') || rel.startsWith('surface/')) return 'deterministic'
  if (rel.startsWith('graph/') || rel.startsWith('rag/') || rel.startsWith('intent/')) return 'semantic'
  return 'semantic'
}

function artifactDigest(a) {
  const buf = readFileSync(a.abs)
  if (a.rel.endsWith('.json')) {
    try { return sha256(JSON.stringify(canonical(JSON.parse(buf.toString('utf8'))))) } catch { /* fall through */ }
  }
  return sha256(buf) // jsonl / md / scip / svg / other: raw bytes
}

const src = sourceDigest()
const artifacts = walk(wakeDir).map(a => ({
  path: `.wake/${a.rel.split(path.sep).join('/')}`,
  bytes: a.bytes,
  layer: layerOf(a.rel.split(path.sep).join('/')),
  sha256: artifactDigest(a),
})).sort((x, y) => x.path.localeCompare(y.path))

const rootDigest = sha256(artifacts.map(a => `${a.path} ${a.sha256}`).join('\n'))

const manifest = {
  schemaVersion: 'wakepoint-manifest-v1',
  repo: 'WakePoint',
  gitCommit: git(['rev-parse', 'HEAD'], 'uncommitted').trim(),
  gitTree: git(['rev-parse', 'HEAD^{tree}'], 'uncommitted').trim(),
  generatedAt: git(['show', '-s', '--format=%cI', 'HEAD'], '1970-01-01T00:00:00+00:00').trim(),
  sourceDigest: src,
  artifactCount: artifacts.length,
  rootDigest,
  artifacts,
}

if (mode === 'write') {
  writeFileSync(manifestPath, JSON.stringify(manifest, null, 2) + '\n')
  console.log(`manifest: ${artifacts.length} artifacts, rootDigest=${rootDigest.slice(0, 16)}, source=${src.slice(0, 16)}`)
} else {
  let prev
  try { prev = JSON.parse(readFileSync(manifestPath, 'utf8')) } catch { console.error('MANIFEST.json missing — run --write first'); process.exit(1) }
  const prevMap = new Map(prev.artifacts.map(a => [a.path, a.sha256]))
  const nowMap = new Map(artifacts.map(a => [a.path, a.sha256]))
  const drift = []
  for (const a of artifacts) if (prevMap.get(a.path) !== a.sha256) drift.push(`${prevMap.has(a.path) ? 'CHANGED' : 'ADDED'} ${a.path}`)
  for (const p of prevMap.keys()) if (!nowMap.has(p)) drift.push(`REMOVED ${p}`)
  const staleSemantic = prev.sourceDigest !== src ? prev.artifacts.filter(a => a.layer === 'semantic').map(a => a.path) : []
  if (drift.length) {
    console.error(`❌ MANIFEST DRIFT (${drift.length}):\n  ` + drift.join('\n  '))
    if (staleSemantic.length) console.error(`\nℹ️  source changed → ${staleSemantic.length} semantic artifacts stale (expected if you edited code; rebuild them).`)
    // Deterministic-layer drift is a hard failure; semantic drift from a source change is expected.
    const detDrift = drift.filter(d => !d.endsWith('.scip') && !/graph\/|rag\/|intent\//.test(d))
    process.exit(detDrift.length ? 1 : 0)
  }
  console.log(`✅ manifest reproduced byte-for-byte (${artifacts.length} artifacts, rootDigest=${rootDigest.slice(0, 16)})`)
  if (staleSemantic.length) console.log(`ℹ️  ${staleSemantic.length} semantic artifacts predate current source — consider rebuilding.`)
}
