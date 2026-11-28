#!/bin/sh
# Sandbox stand-in for the dispatch's prompt: a PreToolUse hook on Agent.
# For an Agent call whose description is "job <cell>", replaces the prompt
# with the cell's prepared prompt file (the task, the tree, the report path,
# the fixtures and the injected plugin text). Any other call passes.
set -eu
in=$(cat)
cell=$(printf '%s' "${in}" | jq -r 'select(.tool_name == "Agent") | .tool_input.description // ""' | sed -n 's/^job \([a-z0-9-]*\)$/\1/p')
[ -n "${cell}" ] || exit 0
p="${REAL_RUN}/cells/${cell}/prompt.txt"
[ -f "${p}" ] || { echo "inject-prompt.sh: no prompt for cell ${cell}" >&2; exit 2; }
printf '%s' "${in}" | jq -c --rawfile p "${p}" '{hookSpecificOutput: {hookEventName: "PreToolUse", updatedInput: (.tool_input + {prompt: $p})}}'
