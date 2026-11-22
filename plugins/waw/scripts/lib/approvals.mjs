// lib/approvals.mjs: what the two approval paths of workers share. approve-mcp.mjs (the
// permission-prompt tool of Claude Code workers) and codex-policy.mjs (the PreToolUse hook of
// Codex workers) both use it: grants of the brief, the commander's approval requests
// (<run dir>/<name>.approvals/a<n>.request.json, an APPROVAL event, a wait for
// a<n>.decision.json from `agent.sh approve|deny`), the decision log and events.

import fs from 'node:fs'
import path from 'node:path'

export const env = process.env
export const NAME = env.AGENT_NAME || 'worker'
export const RUN_DIR = env.AGENT_RUN_DIR || ''
export const SCOPE = env.AGENT_SCOPE || process.cwd()
export const EVENTS = env.AGENT_EVENTS || (RUN_DIR && path.join(RUN_DIR, 'events.log'))
export const WAIT_S = Number(env.AGENT_APPROVAL_WAIT || 480)
export const GRANTS = (env.AGENT_GRANTS || '').split('\n').map((s) => s.trim()).filter(Boolean)
export const FILE_TOOLS = new Set(['Edit', 'Write', 'MultiEdit', 'NotebookEdit'])

export const hhmmss = () => new Date().toTimeString().slice(0, 8)
export const oneLine = (s, n = 200) => String(s ?? '').replace(/\s+/g, ' ').slice(0, n)

export function globToRegExp(glob) {
  let re = ''
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i]
    if (c === '*' && glob[i + 1] === '*') { re += '.*'; i++; if (glob[i + 1] === '/') i++ }
    else if (c === '*') re += '[^/]*'
    else if (c === '?') re += '[^/]'
    else re += c.replace(/[.+^${}()|[\]\\]/g, '\\$&')
  }
  return new RegExp(`^${re}$`)
}

export function granted(rel) {
  return GRANTS.some((g) => {
    const re = globToRegExp(g.replace(/^\.\//, ''))
    return g.includes('/') ? re.test(rel) : re.test(path.basename(rel))
  })
}

export function log(decision, by, tool, target, why = '') {
  if (!RUN_DIR) return
  const line = [new Date().toISOString(), decision, by, tool, target, oneLine(why)].join('\t') + '\n'
  try { fs.appendFileSync(path.join(RUN_DIR, `${NAME}.approvals.log`), line) } catch {}
}

export function event(type, text) {
  if (!EVENTS) return
  try { fs.appendFileSync(EVENTS, `${hhmmss()} ${type} ${NAME}: ${oneLine(text, 400)}\n`) } catch {}
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

export async function askCommander(tool, rel, input) {
  const dir = path.join(RUN_DIR, `${NAME}.approvals`)
  fs.mkdirSync(dir, { recursive: true })
  let n = 1
  while (fs.existsSync(path.join(dir, `a${n}.request.json`))) n++
  const id = `a${n}`
  const what = tool === 'Write' ? 'create or overwrite' : 'edit'
  const preview =
    input.patch ? `patch: ${oneLine(input.patch, 120)}`
    : tool === 'Edit' ? `replace ${oneLine(input.old_string, 80)} -> ${oneLine(input.new_string, 80)}`
    : tool === 'MultiEdit' ? `${(input.edits || []).length} edits`
    : tool === 'Write' ? `${String(input.content ?? '').split('\n').length} lines`
    : ''
  fs.writeFileSync(path.join(dir, `${id}.request.json`),
    JSON.stringify({ id, worker: NAME, tool, file: rel, input, asked: new Date().toISOString() }, null, 2))
  event('APPROVAL', `${id}: ${tool} ${rel} (${what}; ${preview}) is an ask-first file | reply: agent.sh approve ${NAME} ${id} | agent.sh deny ${NAME} ${id} "<reason>"`)
  const decisionFile = path.join(dir, `${id}.decision.json`)
  const deadline = Date.now() + WAIT_S * 1000
  while (Date.now() < deadline) {
    if (fs.existsSync(decisionFile)) {
      try {
        const d = JSON.parse(fs.readFileSync(decisionFile, 'utf8'))
        if (d.behavior === 'allow') {
          log('allow', 'commander', tool, rel, d.message)
          return { behavior: 'allow', updatedInput: input }
        }
        log('deny', 'commander', tool, rel, d.message)
        return { behavior: 'deny', message: `Permission denied by the commander for ${rel}: ${d.message || 'no reason given'}. Do not try another way; finish what you can and report it under out_of_scope_needs.` }
      } catch { /* partly written: read again */ }
    }
    await sleep(1500)
  }
  fs.writeFileSync(path.join(dir, `${id}.timeout`), '')
  event('APPROVAL-TIMEOUT', `${id}: ${tool} ${rel} denied after ${Math.round(WAIT_S / 60)} min without a decision`)
  log('deny', 'timeout', tool, rel)
  return { behavior: 'deny', message: `Permission denied for ${rel}: no approval within ${Math.round(WAIT_S / 60)} minutes. Do not try another way; report the change you need under out_of_scope_needs.` }
}

