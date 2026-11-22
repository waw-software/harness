#!/usr/bin/env node
// approve-mcp.mjs: the permission-prompt tool of workers (claude -p --permission-prompt-tool
// mcp__approver__approve). A minimal MCP server over stdio, no dependencies.
//
// Claude Code calls it whenever a worker's call would show a permission prompt (a project's
// "ask" rule, a hook that answers "ask", a command outside the allowed ones). Decisions:
//   - Edit / Write / MultiEdit / NotebookEdit of a file that matches a grant of the brief
//     (AGENT_GRANTS: globs, one per line, relative to AGENT_SCOPE; `*` no `/`, `**` any,
//     a glob without `/` matches the file name at any depth): allowed at once, logged.
//   - Any other file edit: asks the commander. Writes <run dir>/<name>.approvals/a<n>.request.json,
//     raises an APPROVAL event, waits (AGENT_APPROVAL_WAIT seconds, default 480) for
//     a<n>.decision.json from `agent.sh approve|deny`. No decision in time: denied.
//   - Anything else (a shell command outside the allowed list, another tool): denied at once,
//     with a message that tells the worker to report it instead of trying another form.
// Every decision is appended to <run dir>/<name>.approvals.log (time, decision, by, tool, target).

import path from 'node:path'
import readline from 'node:readline'
import { FILE_TOOLS, RUN_DIR, SCOPE, askCommander, granted, log, oneLine } from './lib/approvals.mjs'

async function decide({ tool_name: tool, input = {} }) {
  if (FILE_TOOLS.has(tool)) {
    const file = input.file_path || input.notebook_path || ''
    const abs = path.resolve(SCOPE, file)
    const rel = path.relative(SCOPE, abs)
    if (!file || rel.startsWith('..') || path.isAbsolute(rel)) {
      log('deny', 'policy', tool, file, 'outside the working directory')
      return { behavior: 'deny', message: `Permission denied: ${file} is outside your working directory.` }
    }
    if (granted(rel)) {
      log('allow', 'grant', tool, rel)
      return { behavior: 'allow', updatedInput: input }
    }
    if (!RUN_DIR) return { behavior: 'deny', message: `Permission denied for ${rel}: no commander to approve it.` }
    return askCommander(tool, rel, input)
  }
  const target = tool === 'Bash' ? oneLine(input.command, 160) : oneLine(JSON.stringify(input), 160)
  log('deny', 'policy', tool, target, 'not pre-approved for workers here')
  return {
    behavior: 'deny',
    message: `Permission denied: ${tool === 'Bash' ? 'this command is' : `${tool} is`} not among the calls workers may make in this project. ` +
      'Do not retry it in another form (another wrapper, a chain, a script). Use a plain allowed command, or report what you needed under concerns.',
  }
}

// ------------------------------------------------------------------ MCP over stdio

const TOOL = {
  name: 'approve',
  description: 'Permission decisions for a worker run by the commander (internal).',
  inputSchema: {
    type: 'object',
    properties: { tool_name: { type: 'string' }, input: { type: 'object' }, tool_use_id: { type: 'string' } },
    required: ['tool_name', 'input'],
  },
}

const send = (msg) => process.stdout.write(JSON.stringify({ jsonrpc: '2.0', ...msg }) + '\n')

const rl = readline.createInterface({ input: process.stdin })
rl.on('line', async (line) => {
  let msg
  try { msg = JSON.parse(line) } catch { return }
  const { id, method, params } = msg
  if (id === undefined) return // notifications
  try {
    if (method === 'initialize') {
      send({ id, result: {
        protocolVersion: params?.protocolVersion || '2025-06-18',
        capabilities: { tools: {} },
        serverInfo: { name: 'approver', version: '1.0.0' },
      } })
    } else if (method === 'tools/list') {
      send({ id, result: { tools: [TOOL] } })
    } else if (method === 'tools/call') {
      if (params?.name !== 'approve') throw new Error(`unknown tool ${params?.name}`)
      const decision = await decide(params.arguments || {})
      send({ id, result: { content: [{ type: 'text', text: JSON.stringify(decision) }] } })
    } else if (method === 'ping') {
      send({ id, result: {} })
    } else {
      send({ id, error: { code: -32601, message: `method not found: ${method}` } })
    }
  } catch (e) {
    send({ id, error: { code: -32603, message: String(e?.message || e) } })
  }
})
