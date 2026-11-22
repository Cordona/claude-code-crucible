#!/usr/bin/env sh
# Run by the question hook (hold-question-until-card-shown.sh) on the hook's
# input: denies a question from main that breaks the gate's shape, naming
# each broken rule.
set -eu
# A hook fault allows the question: a bug here must never block the human.
trap 'exit 0' EXIT

usage() {
	cat <<'EOF'
usage: sh check-question-shape.sh < pre-tool-use-input.json
       sh check-question-shape.sh --help | -h

Run by the question hook, on the hook's input; not for main to call.
It prints a deny when a question breaks the gate's shape, and nothing when
the question is fine. Each question must have:
  - a non-empty question text
  - a first option whose label ends with "(Recommended)"; no other option
    marked so, unless multiSelect is true
  - a non-empty description (the why) on every option
  - no hand-made "Other" option (a label that is just "Other" or
    "Something else"): the dialog always offers one
The option count (2-4) is the tool's own check.

stdin: the hook JSON; reads tool_name, agent_id, tool_input.questions
  Another tool, or a subagent's call (non-empty agent_id), passes untouched.
stdout on a deny:
  {"hookSpecificOutput":{"hookEventName":"PreToolUse",
   "permissionDecision":"deny","permissionDecisionReason":"<broken rules>"}}
Exit: always 0
EOF
}

case ${1-} in -h | --help) usage; exit 0 ;; esac
command -v jq >/dev/null 2>&1 || { printf 'check-question-shape.sh: jq not found\n' >&2; exit 0; }

# shellcheck disable=SC2016 # the $ names are jq's
jq -c '
	def rec: (.label // "") | test("\\(Recommended\\)\\s*$");
	def blank: (. // "") | test("^\\s*$");
	select(.tool_name == "AskUserQuestion" and ((.agent_id // "") == ""))
	| [(.tool_input.questions // [])[] | . as $q
		| ($q.header // $q.question // "a question") as $name
		| ($q.options // []) as $o
		| (if ($q.question | blank) then "\($name): the question text is empty" else empty end),
		  (if ($o | length) > 0 and (($o[0] | rec) | not) then "\($name): the first option must be the recommended one, its label ending with (Recommended). If there are no real options to recommend, take this question out of the dialog and ask it in a plain sentence" else empty end),
		  (if ($q.multiSelect != true) and ($o[1:] | map(select(rec)) | length) > 0 then "\($name): only the first option may be marked (Recommended)" else empty end),
		  ($o[] | select(.description | blank) | "\($name): option \"\(.label)\" needs a description saying why"),
		  ($o[] | select((.label // "") | ascii_downcase | sub("\\(recommended\\)"; "") | test("^\\s*(other|something else)\\W*$"))
			| "\($name): drop option \"\(.label)\"; the dialog always lets the human answer in their own words")]
	| select(length > 0)
	| {hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny",
		permissionDecisionReason: ("Fix the question, then ask again: " + join("; "))}}'
