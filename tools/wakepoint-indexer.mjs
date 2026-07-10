#!/usr/bin/env node
/**
 * WakePoint deterministic atomic-map indexer.
 *
 * Dart-aware, parameterized fork of .agentic-os deterministic-codebase-indexer.mjs.
 * Zero-dependency: node builtins + `git` only. Emits a byte-reproducible knowledge
 * graph (repo -> file -> symbol + import/dependency edges) so the next agent can
 * navigate WakePoint without re-reading the tree.
 *
 * Determinism: source of truth is `git ls-files` (sorted); every timestamp is
 * derived from the HEAD commit (never wall-clock); paths are repo-relative only.
 * Given the same tree + HEAD, output is byte-identical.
 *
 * Usage: node tools/wakepoint-indexer.mjs [repoRoot]   (defaults to repo containing this script)
 */
import { execFileSync } from 'node:child_process'
import { mkdirSync, readFileSync, statSync, writeFileSync } from 'node:fs'
import crypto from 'node:crypto'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const repoRoot = path.resolve(process.argv[2] || process.env.INDEX_REPO_ROOT || path.join(path.dirname(fileURLToPath(import.meta.url)), '..'))
const outputDir = path.join(repoRoot, '.wake', 'map')
mkdirSync(outputDir, { recursive: true })

function git(args, fallback = '') {
  try { return execFileSync('git', args, { cwd: repoRoot, encoding: 'utf8' }).trim() } catch { return fallback }
}

// Deterministic provenance anchors (function of tree + HEAD, not wall-clock).
const gitCommit = git(['rev-parse', 'HEAD'], 'uncommitted')
const gitTree = git(['rev-parse', 'HEAD^{tree}'], 'uncommitted')
const headDate = git(['show', '-s', '--format=%cI', 'HEAD'], '1970-01-01T00:00:00+00:00')

// Detect Dart/Flutter package name from pubspec.yaml (for package: import resolution)
let dartPackage = null
try {
  const pub = readFileSync(path.join(repoRoot, 'pubspec.yaml'), 'utf8')
  const m = pub.match(/^name:\s*([A-Za-z0-9_]+)/m)
  if (m) dartPackage = m[1]
} catch {}

const outputs = {
  knowledgeGraph: path.join(outputDir, 'knowledge-graph.json'),
  moduleInterfaces: path.join(outputDir, 'module-interfaces.jsonl'),
  publicApiSurface: path.join(outputDir, 'public-api-surface.json'),
  typeSignatures: path.join(outputDir, 'type-signatures.jsonl'),
  entryPoints: path.join(outputDir, 'entry-points.json'),
  changeImpact: path.join(outputDir, 'change-impact.json'),
  llmNavigationGuide: path.join(outputDir, 'LLM_NAVIGATION_GUIDE.md'),
}

const trackedFiles = () => execFileSync('git', ['ls-files', '-z'], { cwd: repoRoot, encoding: 'utf8' })
  .split('\0').filter(Boolean).filter(f => !f.startsWith('.wake/') && !f.startsWith('.audit/')).sort()

function sha256(value) { return crypto.createHash('sha256').update(value).digest('hex').slice(0, 16) }

function safeRead(rel) {
  const abs = path.join(repoRoot, rel)
  try { const s = statSync(abs); if (s.size > 2_000_000) return null; return readFileSync(abs, 'utf8') } catch { return null }
}

const JS_EXT = new Set(['.ts', '.tsx', '.js', '.jsx', '.mjs', '.cjs'])

function extractDartInterface(file, text) {
  const iface = { file, lang: 'dart', exports: [], imports: [], types: [], functions: [], classes: [], constants: [], hasDefaultExport: false, hasSideEffects: false }
  if (!text) return iface

  const importRe = /^\s*import\s+'([^']+)'/gm
  let m
  while ((m = importRe.exec(text))) iface.imports.push({ kind: 'static', source: m[1] })
  const exportRe = /^\s*export\s+'([^']+)'/gm
  while ((m = exportRe.exec(text))) iface.imports.push({ kind: 're-export', source: m[1] })
  const partRe = /^\s*part\s+(?:of\s+)?'([^']+)'/gm
  while ((m = partRe.exec(text))) iface.imports.push({ kind: 'part', source: m[1] })

  const classRe = /^\s*(?:abstract\s+|sealed\s+|final\s+|base\s+|interface\s+|mixin\s+)*class\s+([A-Za-z_$][\w$]*)\s*(?:<[^>]*>)?\s*(?:extends\s+([A-Za-z_$][\w$]*))?/gm
  while ((m = classRe.exec(text))) iface.classes.push({ name: m[1], extends: m[2] || null })
  const mixinRe = /^\s*mixin\s+([A-Za-z_$][\w$]*)/gm
  while ((m = mixinRe.exec(text))) iface.classes.push({ name: m[1], extends: null, kind: 'mixin' })

  const enumRe = /^\s*enum\s+([A-Za-z_$][\w$]*)/gm
  while ((m = enumRe.exec(text))) iface.types.push({ name: m[1], kind: 'enum' })
  const typedefRe = /^\s*typedef\s+([A-Za-z_$][\w$]*)/gm
  while ((m = typedefRe.exec(text))) iface.types.push({ name: m[1], kind: 'typedef' })
  const extRe = /^\s*extension\s+([A-Za-z_$][\w$]*)\s+on\s+([A-Za-z_$][\w$<>]*)/gm
  while ((m = extRe.exec(text))) iface.types.push({ name: m[1], kind: 'extension', on: m[2] })

  // top-level functions (column 0 only, to avoid capturing method-body locals)
  const fnRe = /^([A-Za-z_$][\w$<>,.\s?]*?)\s+([A-Za-z_$][\w$]*)\s*\(([^;{]*)\)\s*(?:async\s*)?(?:\{|=>)/gm
  while ((m = fnRe.exec(text))) {
    const name = m[2]
    if (['if', 'for', 'while', 'switch', 'catch', 'return'].includes(name)) continue
    iface.functions.push({ name, signature: `(${m[3].trim()})` })
  }

  // top-level const/final (column 0 only)
  const constRe = /^(?:const|final)\s+(?:[A-Za-z_$][\w$<>,.\s?]*\s+)?([A-Za-z_$][\w$]*)\s*=/gm
  while ((m = constRe.exec(text))) iface.constants.push({ name: m[1] })

  // widget / entrypoint / side-effect flags
  if (/\bextends\s+(?:StatelessWidget|StatefulWidget|State<)/.test(text)) iface.hasSideEffects = false
  const publicNames = new Set()
  for (const c of iface.classes) if (!c.name.startsWith('_')) publicNames.add(c.name), iface.exports.push({ kind: c.kind || 'class', name: c.name })
  for (const t of iface.types) if (!t.name.startsWith('_')) publicNames.add(t.name), iface.exports.push({ kind: t.kind, name: t.name })
  for (const f of iface.functions) if (!f.name.startsWith('_')) iface.exports.push({ kind: 'function', name: f.name })
  for (const c of iface.constants) if (!c.name.startsWith('_')) iface.exports.push({ kind: 'const', name: c.name })

  return iface
}

function extractJsInterface(file, text) {
  const iface = { file, lang: 'js', exports: [], imports: [], types: [], functions: [], classes: [], constants: [], hasDefaultExport: false, hasSideEffects: false }
  if (!text) return iface
  const exportPatterns = [
    [/\bexport\s+default\s+(?:function|class|const|let|var)?\s*([A-Za-z_$][\w$]*)?/g, 'default'],
    [/\bexport\s+(?:async\s+)?function\s+([A-Za-z_$][\w$]*)/g, 'function'],
    [/\bexport\s+const\s+([A-Za-z_$][\w$]*)\s*[:=]/g, 'const'],
    [/\bexport\s+class\s+([A-Za-z_$][\w$]*)/g, 'class'],
    [/\bexport\s+interface\s+([A-Za-z_$][\w$]*)/g, 'interface'],
    [/\bexport\s+type\s+([A-Za-z_$][\w$]*)/g, 'type'],
    [/\bexport\s*\{[^}]*\}\s*from\s+['"]([^'"]+)['"]/g, 're-export'],
    [/\bexport\s*\*\s*from\s+['"]([^'"]+)['"]/g, 're-export-all'],
    [/\bmodule\.exports\s*=/g, 'cjs-default'],
    [/\bexports\.([A-Za-z_$][\w$]*)\s*=/g, 'cjs-named'],
  ]
  for (const [pattern, kind] of exportPatterns) { let m; while ((m = pattern.exec(text))) { if (kind === 'default' || kind === 'cjs-default') { iface.hasDefaultExport = true; continue } iface.exports.push({ kind, name: m[1] || '(anonymous)' }) } }
  const importPatterns = [
    [/\bimport\s+(?:type\s+)?(?:[^'"]+?\s+from\s+)?['"]([^'"]+)['"]/g, 'static'],
    [/\bimport\s*\(\s*['"]([^'"]+)['"]\s*\)/g, 'dynamic'],
    [/\brequire\s*\(\s*['"]([^'"]+)['"]\s*\)/g, 'require'],
  ]
  for (const [pattern, kind] of importPatterns) { let m; while ((m = pattern.exec(text))) iface.imports.push({ kind, source: m[1] }) }
  const fnPattern = /(?:export\s+)?(?:async\s+)?function\s+([A-Za-z_$][\w$]*)\s*\(([^)]*)\)/g
  let m
  while ((m = fnPattern.exec(text))) iface.functions.push({ name: m[1], signature: `(${m[2]})` })
  const arrowPattern = /(?:export\s+)?const\s+([A-Za-z_$][\w$]*)\s*=\s*(?:async\s*)?\(([^)]*)\)\s*=>/g
  while ((m = arrowPattern.exec(text))) iface.functions.push({ name: m[1], signature: `(${m[2]}) =>` })
  const classPattern = /(?:export\s+)?class\s+([A-Za-z_$][\w$]*)\s*(?:extends\s+([A-Za-z_$][\w$]*))?/g
  while ((m = classPattern.exec(text))) iface.classes.push({ name: m[1], extends: m[2] || null })
  const typePattern = /(?:export\s+)?(?:type|interface)\s+([A-Za-z_$][\w$]*)\s*(?:<[^>]*>)?/g
  while ((m = typePattern.exec(text))) iface.types.push({ name: m[1] })
  const constPattern = /export\s+const\s+([A-Za-z_$][\w$]*)\s*=/g
  while ((m = constPattern.exec(text))) iface.constants.push({ name: m[1] })
  return iface
}

function classifyRole(file) {
  if (file.startsWith('lib/')) return 'flutter-lib'
  if (file.startsWith('test/') || file.startsWith('integration_test/') || file.startsWith('test_driver/')) return 'flutter-test'
  if (file.startsWith('geowake-server/')) return 'backend'
  if (file.startsWith('scripts/')) return 'script'
  if (file.startsWith('tools/')) return 'tool'
  if (file.startsWith('docs/')) return 'doc'
  if (file.startsWith('web/') || file.startsWith('android/') || file.startsWith('ios/') || file.startsWith('macos/') || file.startsWith('linux/')) return 'platform'
  return 'other'
}

function resolveDartImport(fromFile, source, trackedSet) {
  if (source.startsWith('dart:')) return null
  if (source.startsWith('package:')) {
    const rest = source.slice('package:'.length)
    const slash = rest.indexOf('/')
    if (slash < 0) return null
    const pkg = rest.slice(0, slash)
    if (dartPackage && pkg === dartPackage) {
      const cand = path.posix.join('lib', rest.slice(slash + 1))
      return trackedSet.has(cand) ? cand : null
    }
    return null
  }
  const baseDir = path.posix.dirname(fromFile)
  const cand = path.posix.normalize(path.posix.join(baseDir, source))
  return trackedSet.has(cand) ? cand : null
}

function resolveJsImport(fromFile, source, trackedSet) {
  if (!source.startsWith('.')) return null
  const baseDir = path.dirname(fromFile)
  const raw = path.posix.normalize(path.posix.join(baseDir, source))
  const candidates = [raw, `${raw}.ts`, `${raw}.tsx`, `${raw}.js`, `${raw}.jsx`, `${raw}.mjs`, `${raw}.cjs`, `${raw}/index.ts`, `${raw}/index.js`]
  return candidates.find(c => trackedSet.has(c)) || null
}

function buildKnowledgeGraph() {
  const files = trackedFiles()
  const trackedSet = new Set(files)
  const interfaces = []
  const dependencyEdges = []
  const exportsByFile = {}
  const publicApi = {}

  for (const file of files) {
    const ext = path.extname(file)
    const isDart = ext === '.dart'
    if (!isDart && !JS_EXT.has(ext)) continue
    const text = safeRead(file)
    if (!text) continue
    const iface = isDart ? extractDartInterface(file, text) : extractJsInterface(file, text)
    iface.role = classifyRole(file)
    iface.contentHash = sha256(text)
    interfaces.push(iface)
    exportsByFile[file] = iface.exports.map(e => ({ ...e, file }))
    for (const imp of iface.imports) {
      const resolved = isDart ? resolveDartImport(file, imp.source, trackedSet) : resolveJsImport(file, imp.source, trackedSet)
      if (resolved) dependencyEdges.push({ from: file, to: resolved, source: imp.source, kind: imp.kind })
    }
    if (iface.exports.length > 0 && !file.includes('.test.') && !file.includes('.spec.') && !/_test\.dart$/.test(file)) publicApi[file] = iface.exports
  }

  const fanIn = {}, fanOut = {}
  for (const e of dependencyEdges) { fanIn[e.to] = (fanIn[e.to] || 0) + 1; fanOut[e.from] = (fanOut[e.from] || 0) + 1 }
  const topFanIn = Object.entries(fanIn).sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0])).slice(0, 30).map(([file, count]) => ({ file, importers: count, exports: exportsByFile[file]?.map(e => e.name) || [] }))
  const topFanOut = Object.entries(fanOut).sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0])).slice(0, 30).map(([file, count]) => ({ file, imports: count }))
  const entryPoints = files.filter(f => { const b = path.basename(f); return b === 'index.ts' || b === 'main.ts' || b === 'app.ts' || b === 'App.tsx' || b === 'main.dart' || b === 'server.js' })
  const changeImpact = topFanIn.map(item => ({ file: item.file, importers: item.importers, directDependents: dependencyEdges.filter(e => e.to === item.file).map(e => e.from).sort(), exportedSymbols: item.exports, riskLevel: item.importers > 10 ? 'critical' : item.importers > 5 ? 'high' : 'medium' }))

  // deterministic role rollup
  const byRole = {}
  for (const i of interfaces) byRole[i.role] = (byRole[i.role] || 0) + 1

  return {
    summary: {
      schemaVersion: 'wakepoint-deterministic-index-v1',
      repoRoot: '.',
      packageName: dartPackage,
      gitCommit, gitTree, generatedAt: headDate,
      filesIndexed: interfaces.length,
      dependencyEdges: dependencyEdges.length,
      totalExports: interfaces.reduce((s, i) => s + i.exports.length, 0),
      totalImports: interfaces.reduce((s, i) => s + i.imports.length, 0),
      byRole,
      entryPoints,
    },
    interfaces, dependencyEdges, publicApi, topFanIn, topFanOut, changeImpact,
  }
}

function writeLLMNavigationGuide(graph) {
  const s = graph.summary
  const byRole = {}
  for (const i of graph.interfaces) (byRole[i.role] = byRole[i.role] || []).push(i.file)
  const lines = []
  lines.push('# WakePoint — LLM Navigation Guide (deterministic)')
  lines.push('')
  lines.push('> Auto-generated by `tools/wakepoint-indexer.mjs`. Do not edit by hand — run the indexer.')
  lines.push(`> Built against commit \`${s.gitCommit}\` (tree \`${s.gitTree}\`), ${s.generatedAt}.`)
  lines.push('')
  lines.push(`- **Package**: \`${s.packageName}\`  •  **Files indexed**: ${s.filesIndexed}  •  **Import edges**: ${s.dependencyEdges}  •  **Exports**: ${s.totalExports}`)
  lines.push('')
  lines.push('## Entry points')
  for (const e of s.entryPoints) lines.push(`- \`${e}\``)
  lines.push('')
  lines.push('## Highest-impact files (top fan-in — change these carefully)')
  lines.push('')
  lines.push('| File | Importers | Risk |')
  lines.push('|------|-----------|------|')
  for (const c of graph.changeImpact.slice(0, 15)) lines.push(`| \`${c.file}\` | ${c.importers} | ${c.riskLevel} |`)
  lines.push('')
  lines.push('## Files by role')
  for (const role of Object.keys(byRole).sort()) lines.push(`- **${role}**: ${byRole[role].length}`)
  lines.push('')
  return lines.join('\n') + '\n'
}

const graph = buildKnowledgeGraph()
writeFileSync(outputs.knowledgeGraph, JSON.stringify(graph, null, 2))
writeFileSync(outputs.moduleInterfaces, graph.interfaces.map(r => JSON.stringify(r)).join('\n') + '\n')
writeFileSync(outputs.publicApiSurface, JSON.stringify(graph.publicApi, null, 2))
writeFileSync(outputs.typeSignatures, graph.interfaces.flatMap(i => i.functions.map(f => ({ file: i.file, name: f.name, signature: f.signature }))).map(r => JSON.stringify(r)).join('\n') + '\n')
writeFileSync(outputs.entryPoints, JSON.stringify(graph.summary.entryPoints, null, 2))
writeFileSync(outputs.changeImpact, JSON.stringify(graph.changeImpact, null, 2))
writeFileSync(outputs.llmNavigationGuide, writeLLMNavigationGuide(graph))
console.log(`files=${graph.summary.filesIndexed} edges=${graph.summary.dependencyEdges} exports=${graph.summary.totalExports} imports=${graph.summary.totalImports} pkg=${dartPackage} commit=${gitCommit.slice(0, 8)}`)
