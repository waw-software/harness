# codex-stream.jq: the JSONL events of `codex exec --json` as Claude Code stream-json lines,
# so that agent.sh follows, lists and sums a Codex worker exactly like a Claude Code one.
# Run as: jq -n --unbuffered -c -f codex-stream.jq (one input event per line).
#   thread.started               -> {type: system, subtype: init, session_id}
#   item.started command         -> assistant tool_use Bash {command}
#   item.completed command       -> user tool_result (is_error when the exit code is not 0)
#   item.completed file_change   -> assistant tool_use Edit {file_path} + its tool_result, per file
#   item.completed agent_message -> assistant text (the last one is the report)
#   item.completed error         -> assistant text "codex: ..." (the hook-trust notice is dropped)
#   turn.completed               -> result: usage (input split into uncached / cache read),
#                                   num_turns (tool calls), structured_output (the last message)
#   turn.failed, error           -> result with is_error and the message
def unwrap: if test("^/bin/(ba|z)?sh -l?c '") then sub("^/bin/(ba|z)?sh -l?c '"; "") | sub("'$"; "") | gsub("'\\\\''"; "'")
  elif test("^/bin/(ba|z)?sh -l?c \"") then sub("^/bin/(ba|z)?sh -l?c \""; "") | sub("\"$"; "") | gsub("\\\\(?<c>[\"\\\\$`])"; "\(.c)")
  else . end;
def tail_text($n): (. // "") | tostring | if length > $n then .[-$n:] else . end;
def tool_use($name; $input; $id): {type: "assistant", message: {content: [{type: "tool_use", id: $id, name: $name, input: $input}]}};
def tool_result($id; $err; $text): {type: "user", message: {content: [{type: "tool_result", tool_use_id: $id, is_error: $err, content: $text}]}};
def report: (. // "") as $t | (try ($t | fromjson) catch null) | if type == "object" then . else null end;
foreach (inputs | select(type == "object")) as $e (
  {last: null, calls: 0, out: []};
  .out = []
  | if $e.type == "thread.started" then
      .out = [{type: "system", subtype: "init", session_id: $e.thread_id, runtime: "codex"}]
    elif $e.type == "item.started" and $e.item.type == "command_execution" then
      .calls += 1
      | .out = [tool_use("Bash"; {command: ($e.item.command // "" | unwrap)}; $e.item.id)]
    elif $e.type == "item.completed" and $e.item.type == "command_execution" then
      .out = [tool_result($e.item.id; (($e.item.exit_code // 0) != 0 or $e.item.status == "failed" or $e.item.status == "declined");
        ($e.item.aggregated_output | tail_text(600)))]
    elif $e.type == "item.completed" and $e.item.type == "file_change" then
      .calls += 1
      | .out = [($e.item.changes // [])[] as $c
          | (tool_use(if $c.kind == "add" then "Write" else "Edit" end; {file_path: $c.path}; "\($e.item.id)-\($c.path)"),
             tool_result("\($e.item.id)-\($c.path)"; ($e.item.status == "failed"); "\($c.kind // "update") \($c.path)"))]
    elif $e.type == "item.completed" and $e.item.type == "agent_message" then
      .last = $e.item.text
      | .out = [{type: "assistant", message: {content: [{type: "text", text: ($e.item.text // "")}]}}]
    elif $e.type == "item.completed" and $e.item.type == "error" then
      if ($e.item.message // "" | test("dangerously-bypass-hook-trust")) then .
      else .out = [{type: "assistant", message: {content: [{type: "text", text: "codex: \($e.item.message // "")"}]}}] end
    elif $e.type == "turn.completed" then
      ($e.usage // {}) as $u
      | .out = [{type: "result", subtype: "success", is_error: false, num_turns: .calls, total_cost_usd: 0,
          usage: {input_tokens: (($u.input_tokens // 0) - ($u.cached_input_tokens // 0)),
                  cache_read_input_tokens: ($u.cached_input_tokens // 0),
                  cache_creation_input_tokens: ($u.cache_write_input_tokens // 0),
                  output_tokens: ($u.output_tokens // 0)},
          result: (.last // ""), structured_output: (.last | report)}]
    elif $e.type == "turn.failed" or $e.type == "error" then
      .out = [{type: "result", subtype: "error_during_execution", is_error: true, num_turns: .calls, total_cost_usd: 0,
          usage: {}, result: ($e.error.message // $e.message // "codex failed")}]
    else . end;
  .out[])
