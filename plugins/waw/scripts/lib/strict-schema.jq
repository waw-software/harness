# strict-schema.jq: a role schema (schemas/<role>.json) in the strict form that Codex's
# --output-schema takes (OpenAI structured outputs): every object lists all its properties in
# `required` and has additionalProperties false; a property the role schema leaves optional
# becomes nullable (its type, or its enum, also takes null). agent.sh drops the nulls from the
# report afterwards, so the report has the role schema's shape again.
def nullable:
  (if has("type") then .type |= (if type == "array" then (. + ["null"] | unique) else [., "null"] end) else . end)
  | (if has("enum") then .enum |= (. + [null] | unique) else . end);
walk(
  if type == "object" and .type == "object" and has("properties") then
    (.required // []) as $req
    | .properties |= with_entries(.key as $k | if any($req[]; . == $k) then . else .value |= nullable end)
    | .required = (.properties | keys)
    | .additionalProperties = false
  else . end)
