#!/usr/bin/env node
/**
 * WakePoint codebase-RAG index builder.
 *
 * Reuses .agentic-os CodebaseRAG (offline, deterministic lexical/symbol retrieval)
 * to build a queryable index over the WakePoint sources, then copies it into
 * .wake/rag/codebase-index.json for in-repo colocation.
 *
 * The next agent queries it instead of re-reading files:
 *   const { CodebaseRAG } = await import('/home/raed/.agentic-os/scripts/codebase-rag.mjs')
 *   const rag = new CodebaseRAG({ repoRoot, projectSlug: 'WakePoint' })
 *   rag.loadIndexFrom('.wake/rag/codebase-index.json')   // or rag.index()
 *   const hits = await rag.search('geofence alarm trigger', { limit: 5 })
 *   // -> [{ relativePath, lines, symbol, symbolType, score }]  Read only those spans.
 */
import { copyFileSync, mkdirSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { CodebaseRAG } from '/home/raed/.agentic-os/scripts/codebase-rag.mjs'

const repoRoot = path.resolve(process.argv[2] || path.join(path.dirname(fileURLToPath(import.meta.url)), '..'))
const outDir = path.join(repoRoot, '.wake', 'rag')
mkdirSync(outDir, { recursive: true })

const rag = new CodebaseRAG({
  repoRoot,
  projectSlug: 'WakePoint',
  extensions: ['.dart', '.py', '.js', '.mjs', '.cjs', '.ts', '.tsx', '.json', '.yaml', '.yml', '.md', '.sh', '.swift', '.kt', '.java'],
  includePrefixes: ['lib', 'test', 'integration_test', 'geowake-server/src', 'scripts', 'tools'],
})

const n = await rag.index()
const dest = path.join(outDir, 'codebase-index.json')
copyFileSync(rag.indexPath, dest)
console.log(`rag chunks=${n} -> ${path.relative(repoRoot, dest)}`)
