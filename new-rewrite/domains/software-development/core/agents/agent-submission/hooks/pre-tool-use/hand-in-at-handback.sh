#!/usr/bin/env sh
# Claude Code PreToolUse hook on SubagentHandback: hands in a job agent's work
# at its handback, the door an agent in auto mode leaves by, so a refused
# report is sent back for repair before it is delivered. The same check as
# the stop hook: it runs submit-agent-work.sh.
set -eu

usage() {
	cat <<'USAGE'
usage: sh hand-in-at-handback.sh < PRE_TOOL_USE_HOOK_JSON

Run by Claude Code as the PreToolUse hook on SubagentHandback; not for main
to call. Runs subagent-stop/submit-agent-work.sh on its input: its contract
is that script's.
Exit:
  0  always
USAGE
}

case ${1-} in -h | --help) usage; exit 0 ;; *) ;; esac
exec sh "$(cd -- "$(dirname -- "$0")/../subagent-stop" && pwd)/submit-agent-work.sh"
