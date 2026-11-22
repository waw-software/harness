#!/usr/bin/env node
// codex-policy.mjs: a project's Claude Code permission rules, enforced for Codex workers.
// Codex does not read .claude/settings.json, so agent.sh and the Codex worker's PreToolUse hook
// (hooks/codex-pre-tool.sh) use this instead. No dependencies.
//
//   node codex-policy.mjs check <dir>         exit 0 when every deny/ask rule of <dir>'s
//                                             .claude/settings.json and settings.local.json
//                                             can be enforced for Codex; exit 3 with the rules
//                                             that cannot (agent.sh then uses the fallback route)
//   node codex-policy.mjs read-denies <dir>   the paths those rules keep from Read, as a JSON
//                                             object of Codex filesystem entries ({path: "deny"},
//                                             globs under ":workspace_roots"), for the sandbox
//   node codex-policy.mjs hook                the hook: the hook JSON on stdin (tool_name Bash
//                                             or apply_patch); exit 0 allows, exit 2 blocks
//                                             with the reason on stderr
//
// What the hook enforces, like Claude Code does for a Claude worker:
//   - a deny rule on Bash, Edit or Write: blocked;
//   - an ask rule on Bash: blocked (a headless worker has nobody to ask); on Edit or Write: a
//     grant of the brief (AGENT_GRANTS) passes, anything else asks the commander (APPROVAL,
//     lib/approvals.mjs) and waits for `agent.sh approve|deny`;
//   - a project that sets permissions.disableBypassPermissionsMode (AGENT_ALLOWED holds the
//     role's pre-approved rules, one per line, as agent.sh allowed_of gives them, plus the
//     project's own allow rules): each command of a Bash call must match one of them.
// Read rules go to the sandbox (read-denies), Glob and Grep rules with them. Rules on tools a
// Codex worker does not have (WebFetch, WebSearch, MCP tools, Agent, Task, ...) hold by
// themselves. Any other rule cannot be translated: check reports it.
//
// Rule syntax (Claude Code's): Tool, or Tool(specifier). Bash: "npm run build" (exact),
// "npm run test:*" (prefix), "*" wildcards. Paths: "//abs" absolute, "~/x" in the home,
// "/x" relative to the project root, "./x" or "x" relative to the project root too (the
// worker's cwd is the root); gitignore-like globs, a pattern without "/" matches the file name
// at any depth.

import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { SCOPE, askCommander, globToRegExp, granted, log, oneLine } from './lib/approvals.mjs'

const NOT_THERE = new Set(['WebFetch', 'WebSearch', 'Agent', 'Task', 'TodoWrite', 'Skill', 'NotebookRead',
  'ExitPlanMode', 'EnterPlanMode', 'BashOutput', 'KillShell', 'SlashCommand', 'ListMcpResourcesTool',
  'ReadMcpResourceTool', 'AskUserQuestion', 'EnterWorktree', 'ExitWorktree', 'Monitor', 'ToolSearch'])
const FILE_EDIT = new Set(['Edit', 'Write', 'MultiEdit', 'NotebookEdit'])
const FILE_READ = new Set(['Read', 'Glob', 'Grep'])

function parseRule(r) {
  const m = /^([A-Za-z_][A-Za-z0-9_]*)(?:\((.*)\))?$/s.exec(String(r).trim())
  return m ? { tool: m[1], spec: m[2] ?? null, text: String(r) } : { tool: null, spec: null, text: String(r) }
}

function projectRules(dir) {
  const out = { deny: [], ask: [], allow: [], bypassDisabled: false }
  for (const f of ['settings.json', 'settings.local.json']) {
    let j
    try { j = JSON.parse(fs.readFileSync(path.join(dir, '.claude', f), 'utf8')) } catch { continue }
    const p = j?.permissions || {}
    for (const k of ['deny', 'ask', 'allow']) if (Array.isArray(p[k])) out[k].push(...p[k].map(parseRule))
    if (p.disableBypassPermissionsMode === 'disable') out.bypassDisabled = true
  }
  return out
}

function untranslatable(rules) {
  return [...rules.deny, ...rules.ask].filter((r) =>
    !r.tool || !(r.tool === 'Bash' || FILE_EDIT.has(r.tool) || FILE_READ.has(r.tool) ||
      NOT_THERE.has(r.tool) || r.tool.startsWith('mcp__')))
}

// ------------------------------------------------------------------ matching

// A path rule as {abs} (an absolute path or glob) or {rel} (relative to the project root).
function pathSpec(spec) {
  if (spec == null || spec === '' || spec === '*' || spec === '**') return { rel: '**' }
  if (spec.startsWith('//')) return { abs: spec.slice(1) }
  if (spec.startsWith('~/')) return { abs: path.join(os.homedir(), spec.slice(2)) }
  return { rel: spec.replace(/^\.?\//, '') }
}

function pathMatches(spec, absFile, root) {
  const s = pathSpec(spec)
  const pat = (s.abs ?? s.rel).replace(/\/$/, '/**')
  if (s.abs) return globToRegExp(pat).test(absFile)
  const rel = path.relative(root, absFile)
  if (rel.startsWith('..') || path.isAbsolute(rel)) return false
  const re = globToRegExp(pat)
  return pat.includes('/') ? re.test(rel) : (re.test(path.basename(rel)) || re.test(rel))
}

function bashMatches(spec, cmd) {
  if (spec == null || spec === '' || spec === '*') return true
  const c = cmd.trim()
  if (spec.endsWith(':*')) {
    const pre = spec.slice(0, -2)
    return c === pre || c.startsWith(pre + ' ') || (pre.endsWith(' ') && c.startsWith(pre))
  }
  if (spec.includes('*')) {
    const re = new RegExp('^' + spec.split('*').map((x) => x.replace(/[.+?^${}()|[\]\\]/g, '\\$&')).join('.*') + '$')
    return re.test(c)
  }
  return c === spec
}

// The commands of a shell line: split on ; & | ( ) and newlines, outside quotes; leading
// assignments and wrappers (env, timeout <n>, ...) kept, as Claude Code's prefix rules see them.
function segments(cmd) {
  const out = []
  let cur = '', q = null
  for (let i = 0; i < cmd.length; i++) {
    const ch = cmd[i]
    if (q) { cur += ch; if (ch === q && cmd[i - 1] !== '\\') q = null; continue }
    if (ch === '"' || ch === "'") { q = ch; cur += ch; continue }
    if (';&|()\n`'.includes(ch)) { if (cur.trim()) out.push(cur.trim()); cur = ''; continue }
    cur += ch
  }
  if (cur.trim()) out.push(cur.trim())
  return out.map((s) => s.replace(/^(?:[A-Za-z_][A-Za-z0-9_]*=\S*\s+)+/, ''))
}

// The files of an apply_patch call: its "*** Add/Update/Delete File:" and "*** Move to:" lines.
export function patchFiles(patch, cwd) {
  const files = []
  for (const line of String(patch || '').split('\n')) {
    const m = /^\*\*\* (?:(Add|Update|Delete) File|Move to): (.+)$/.exec(line.trimEnd())
    if (m) files.push({ kind: m[1] || 'Move', file: path.resolve(cwd, m[2].trim()) })
  }
  return files
}

// ------------------------------------------------------------------ the hook

function block(why) {
  process.stderr.write(`${why}\n`)
  process.exit(2)
}

async function hook() {
  let input
  try { input = JSON.parse(fs.readFileSync(0, 'utf8')) } catch { process.exit(0) }
  const tool = input.tool_name
  const root = SCOPE
  const rules = projectRules(root)
  const allowed = (process.env.AGENT_ALLOWED || '').split('\n').map((s) => s.trim()).filter(Boolean)
    .map(parseRule).concat(rules.allow)

  if (tool === 'Bash') {
    const cmd = String(input.tool_input?.command ?? '')
    for (const seg of segments(cmd)) {
      const hit = (list) => list.find((r) => r.tool === 'Bash' && bashMatches(r.spec, seg))
      const d = hit(rules.deny)
      if (d) { log('deny', 'project', 'Bash', oneLine(seg, 160), d.text); block(`waw policy: blocked \`${oneLine(seg, 80)}\`: the project denies it (${d.text}). Do not try another form; report what you needed under concerns.`) }
      const a = hit(rules.ask)
      if (a) { log('deny', 'project', 'Bash', oneLine(seg, 160), a.text); block(`waw policy: blocked \`${oneLine(seg, 80)}\`: the project asks before it (${a.text}) and a worker has nobody to ask. Report what you needed under concerns.`) }
      if (process.env.AGENT_BYPASS_DISABLED === '1' && !allowed.some((r) => r.tool === 'Bash' && bashMatches(r.spec, seg))) {
        log('deny', 'policy', 'Bash', oneLine(seg, 160), 'not pre-approved for workers here')
        block(`waw policy: \`${oneLine(seg, 80)}\` is not among the calls workers may make in this project. Do not retry it in another form (another wrapper, a chain, a script). Use a plain allowed command, or report what you needed under concerns.`)
      }
    }
    process.exit(0)
  }

  if (tool === 'apply_patch' || FILE_EDIT.has(tool)) {
    const cwd = input.cwd || root
    const files = tool === 'apply_patch'
      ? patchFiles(input.tool_input?.command ?? input.tool_input?.patch ?? '', cwd)
      : [{ kind: 'Update', file: path.resolve(cwd, input.tool_input?.file_path || '') }]
    for (const { kind, file } of files) {
      const ruleTool = kind === 'Add' ? 'Write' : 'Edit'
      const hit = (list) => list.find((r) => FILE_EDIT.has(r.tool) && (r.tool === ruleTool || r.tool === 'Edit' || r.tool === 'Write') && pathMatches(r.spec, file, root))
      const rel = path.relative(root, file)
      const d = hit(rules.deny)
      if (d) { log('deny', 'project', ruleTool, rel, d.text); block(`waw policy: blocked a write to ${rel}: the project denies it (${d.text}). Report the change you need under out_of_scope_needs.`) }
      const a = hit(rules.ask)
      if (a) {
        if (granted(rel)) { log('allow', 'grant', ruleTool, rel); continue }
        const r = await askCommander(ruleTool, rel, { file_path: file, patch: oneLine(input.tool_input?.command, 400) })
        if (r.behavior !== 'allow') block(r.message)
      }
    }
    process.exit(0)
  }
  process.exit(0)
}

// ------------------------------------------------------------------ main

const [mode, dir] = process.argv.slice(2)
if (mode === 'check') {
  const bad = untranslatable(projectRules(dir || '.'))
  if (bad.length) { process.stderr.write(`rules Codex workers cannot follow: ${bad.map((r) => r.text).join(', ')}\n`); process.exit(3) }
  process.exit(0)
} else if (mode === 'read-denies') {
  const root = dir || '.'
  const rules = projectRules(root)
  const out = {}
  const ws = {}
  for (const r of [...rules.deny, ...rules.ask]) {
    if (!FILE_READ.has(r.tool)) continue
    const s = pathSpec(r.spec)
    if (s.abs) out[s.abs.replace(/\/\*\*$/, '')] = 'deny'
    else {
      const p = s.rel.replace(/\/$/, '/**')
      if (p === '**') continue // "Read" without a path: everything; the worker could not work
      ws[p.includes('/') ? p : `**/${p}`] = 'deny'
    }
  }
  if (Object.keys(ws).length) out[':workspace_roots'] = ws
  process.stdout.write(JSON.stringify(out) + '\n')
} else if (mode === 'hook') {
  await hook()
} else {
  process.stderr.write('usage: codex-policy.mjs check <dir> | read-denies <dir> | hook\n')
  process.exit(2)
}
