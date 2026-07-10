#!/usr/bin/env node
/**
 * WakePoint map updater — single entrypoint that keeps the .wake/ map fresh.
 *
 * Two tiers (see .wake/AGENT_CONTEXT.md and README):
 *   --fast (default): DETERMINISTIC layers only — file/import map, coverage ledger,
 *       structural intent-graph, manifest. Sub-second; safe to run in a git hook.
 *   --semantic: SLOW / env-dependent — flutter pub get + scip-dart + decode + RAG,
 *       then rebuild intent-graph + manifest. Run manually or detached.
 *   --all: fast then semantic.
 *   --check: assert byte-reproducibility of the deterministic layers (manifest --check).
 *
 * Usage: node tools/wakepoint-update.mjs [--fast|--semantic|--all|--check] [repoRoot]
 */
import { execFileSync } from 'node:child_process'
import { writeFileSync, readFileSync, existsSync, rmSync } from 'node:fs'
import crypto from 'node:crypto'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const args = process.argv.slice(2)
const mode = args.find(a => ['--fast', '--semantic', '--all', '--check', '--stale-check'].includes(a))?.replace('--', '') || 'fast'
const repoRoot = path.resolve(args.find(a => !a.startsWith('--')) || path.join(path.dirname(fileURLToPath(import.meta.url)), '..'))
const T = (p) => path.join(repoRoot, 'tools', p)
const FLUTTER_BIN = process.env.FLUTTER_BIN || '/home/raed/flutter/bin'
const SCIP_DART = process.env.SCIP_DART || '/home/raed/.local/bin/scip-dart'

function run(cmd, cmdArgs, opts = {}) {
  process.stdout.write(`  › ${path.basename(cmd)} ${cmdArgs.join(' ')}\n`)
  execFileSync(cmd, cmdArgs, { cwd: repoRoot, stdio: 'inherit', ...opts })
}

function fast() {
  console.log('[fast] deterministic layers')
  run('node', [T('wakepoint-indexer.mjs'), repoRoot])
  run('node', [T('wakepoint-coverage-ledger.mjs'), repoRoot])
  run('node', [T('wakepoint-build-intent-graph.mjs'), repoRoot])
  run('node', [T('wake-manifest.mjs'), '--write'])
}

// Fingerprint of everything the Dart semantic layer depends on (dart sources + resolved deps).
function dartFingerprint() {
  const files = execFileSync('git', ['ls-files', '-s', '--', '*.dart', 'pubspec.yaml', 'pubspec.lock'], { cwd: repoRoot, encoding: 'utf8' })
  return crypto.createHash('sha256').update(files).digest('hex')
}
const SEMANTIC_MARKER = path.join(repoRoot, '.wake/graph/.semantic-source')
const STALE = path.join(repoRoot, '.wake/STALE')

function semantic() {
  console.log('[semantic] scip-dart + rag (slow, env-dependent)')
  run(path.join(FLUTTER_BIN, 'flutter'), ['pub', 'get'], { env: { ...process.env, PATH: `${FLUTTER_BIN}:${process.env.PATH}` } })
  run(SCIP_DART, ['--output', path.join(repoRoot, '.wake/graph/scip-dart.scip'), repoRoot])
  run('node', [T('wakepoint-decode-scip.mjs'), repoRoot])
  run('node', [T('wakepoint-rag.mjs'), repoRoot])
  run('node', [T('wakepoint-build-intent-graph.mjs'), repoRoot])
  run('node', [T('wake-manifest.mjs'), '--write'])
  writeFileSync(SEMANTIC_MARKER, dartFingerprint() + '\n')
  if (existsSync(STALE)) rmSync(STALE)
}

// Compare current Dart source to what the semantic layer was built against; flag STALE.
function staleCheck() {
  const now = dartFingerprint()
  const built = existsSync(SEMANTIC_MARKER) ? readFileSync(SEMANTIC_MARKER, 'utf8').trim() : ''
  if (now !== built) {
    writeFileSync(STALE, `Dart source changed since the semantic layer (scip/rag/intent) was built.\nRun: node tools/wakepoint-update.mjs --semantic\nnow=${now}\nbuilt=${built || '(never)'}\n`)
    console.log('⚠️  .wake/STALE set — semantic layers need rebuild (node tools/wakepoint-update.mjs --semantic)')
  } else {
    if (existsSync(STALE)) rmSync(STALE)
    console.log('✅ semantic layers fresh')
  }
}

if (mode === 'check') run('node', [T('wake-manifest.mjs'), '--check'])
else if (mode === 'fast') fast()
else if (mode === 'semantic') semantic()
else if (mode === 'all') { fast(); semantic() }
else if (mode === 'stale-check') staleCheck()
console.log(`[done] mode=${mode}`)
