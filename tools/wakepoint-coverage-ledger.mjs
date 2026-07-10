#!/usr/bin/env node
/**
 * WakePoint coverage ledger — the single canonical record of HOW DEEPLY each
 * language is mapped, on the .agentic-os L1-L7 scale, with honest gap reasons.
 *
 *   L1 file universe | L2 syntax | L3 symbols | L4 imports/refs | L5 call graph | L6 dataflow | L7 runtime
 *
 * Deterministic: derived purely from the already-built .wake artifacts.
 * Usage: node tools/wakepoint-coverage-ledger.mjs [repoRoot]
 */
import { execFileSync } from 'node:child_process'
import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const repoRoot = path.resolve(process.argv[2] || path.join(path.dirname(fileURLToPath(import.meta.url)), '..'))
const outDir = path.join(repoRoot, '.wake/surface')
mkdirSync(outDir, { recursive: true })
const git = (a, fb = '') => { try { return execFileSync('git', a, { cwd: repoRoot, encoding: 'utf8' }).trim() } catch { return fb } }
const readJson = (p) => existsSync(p) ? JSON.parse(readFileSync(p, 'utf8')) : null

const map = readJson(path.join(repoRoot, '.wake/map/knowledge-graph.json'))
const dartSym = readJson(path.join(repoRoot, '.wake/graph/dart-symbol-graph.json'))
const backend = readJson(path.join(repoRoot, '.wake/graph/backend-call-graph.json'))

const dartFiles = map.interfaces.filter(i => i.lang === 'dart')
const jsFiles = map.interfaces.filter(i => i.lang === 'js')

const languages = [
  {
    language: 'dart',
    files: dartFiles.length,
    currentLevel: 'L4-references',
    maxObservableLevel: 'L5-call-hierarchy',
    levels: {
      L1: { status: 'complete', by: 'git ls-files + wakepoint-indexer' },
      L2: { status: 'partial', by: 'regex structural extraction (indexer)', note: 'not full AST; class members not enumerated' },
      L3: { status: 'complete', by: 'scip-dart 1.6.2', definitions: dartSym?.summary.definitionCount ?? 0 },
      L4: { status: 'complete', by: 'scip-dart references', referenceEdges: dartSym?.summary.referenceEdgeCount ?? 0, flutterExternalRefs: dartSym?.summary.externalFlutterRefOccurrences ?? 0 },
      L5: { status: 'partial', by: 'none (dart LSP call-hierarchy not exported)', gapReason: 'scip-dart emits definitions+references, not caller->callee call edges; dart LSP call-hierarchy would close this' },
      L6: { status: 'none', gapReason: 'no dataflow/type-hierarchy tool wired for Dart' },
      L7: { status: 'none', gapReason: 'no runtime trace capture' },
    },
  },
  {
    language: 'javascript',
    files: jsFiles.length,
    currentLevel: 'L5-call-graph',
    maxObservableLevel: 'L5-call-graph',
    levels: {
      L1: { status: 'complete', by: 'wakepoint-indexer' },
      L2: { status: 'partial', by: 'regex structural extraction' },
      L3: { status: 'complete', by: 'symbol-call-graph.mjs', symbols: backend?.summary?.symbolCount ?? backend?.symbols?.length ?? null },
      L4: { status: 'complete', by: 'import resolution (indexer + symbol-call-graph)' },
      L5: { status: 'partial', by: 'symbol-call-graph call edges', note: 'geowake-server scope only; few dynamic call sites' },
      L6: { status: 'none' },
      L7: { status: 'none' },
    },
  },
]

const ledger = {
  schemaVersion: 'wakepoint-coverage-ledger-v1',
  gitCommit: git(['rev-parse', 'HEAD'], 'uncommitted'),
  generatedAt: git(['show', '-s', '--format=%cI', 'HEAD'], '1970-01-01T00:00:00+00:00'),
  surfaceSha256: map.summary.gitTree,
  verdict: 'complete-visible-surface + complete-dart-symbol-references + partial-call-graph; gaps: Dart L5 call-hierarchy, L6/L7',
  toolchain: {
    dart: 'scip-dart 1.6.2 (Dart 3.12.2, Flutter 3.44.6 resolved)',
    javascript: '.agentic-os symbol-call-graph.mjs (TS compiler API)',
    fileSurface: 'wakepoint-indexer.mjs (regex, zero-dep)',
    rag: '.agentic-os CodebaseRAG (offline BM25/lexical)',
  },
  languages,
  boundaries: [
    'Dart symbol extraction in the file map is regex-based (deterministic but not AST-exact); scip-dart provides the authoritative Dart symbol/reference layer.',
    'Dart call edges (who-calls-whom) are not captured; only definitions and references. LSP call-hierarchy would add them.',
    'Native platform code (Kotlin/Swift/C++ under android|ios|macos|linux) is inventoried at L1 only.',
    'Backend call graph is scoped to geowake-server (whole-repo symbol-call-graph run does not terminate in time).',
  ],
}
writeFileSync(path.join(outDir, 'coverage-ledger.json'), JSON.stringify(ledger, null, 2))
console.log(`coverage-ledger: dart ${dartFiles.length}f @ ${languages[0].currentLevel}, js ${jsFiles.length}f @ ${languages[1].currentLevel}`)
