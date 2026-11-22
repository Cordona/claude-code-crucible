#!/usr/bin/env sh
# Claude Code PreToolUse hook for Bash: denies a command that runs the event
# writer directly, by mistake. Events are written by their component's scripts.
set -eu
# A hook fault allows the call: it sits on every Bash call, and a bug here
# must never block the human.
trap 'exit 0' EXIT

usage() {
	cat <<'EOF'
usage: sh deny-direct-event-write.sh < pre-tool-use-input.json
       sh deny-direct-event-write.sh --help | -h

A Claude Code PreToolUse hook for Bash. Denies a command that runs
event-write.sh: a command word ending in event-write.sh, or one given to a
shell (sh, bash, dash, zsh, ., source; a -c string is read the same
way), after any VAR=value and the wrappers env, exec, nice, nohup, time, command, sudo and timeout <n>. Allowed: a run
with only --help or -h, any command that only reads or names the file (cat,
sed, grep, ls, echo, ...), and every component script that calls the writer
itself, which is no Bash tool call.

It guards against a run by mistake, not a determined one: a name the shell
builds (expansion, variables, eval) or a run by indirection (a copy, a pipe
into a shell) is not caught.

A command that doesn't mention event-write.sh is allowed at once. On any
fault (jq missing, input it can't read) the call is allowed, with a note on
stderr.

stdin: the hook JSON; reads tool_name, tool_input.command
stdout on a deny:
  {"hookSpecificOutput":{"hookEventName":"PreToolUse",
   "permissionDecision":"deny","permissionDecisionReason":"<why>"}}
Exit: always 0
EOF
}

case ${1-} in -h | --help) usage; exit 0 ;; esac

input=$(cat)
case ${input} in *event-write.sh*) ;; *) exit 0 ;; esac
if ! command -v jq >/dev/null 2>&1; then
	echo 'deny-direct-event-write.sh: jq missing; the call is allowed unchecked' >&2
	exit 0
fi
tool=$(printf '%s' "${input}" | jq -r '.tool_name // empty' 2>/dev/null) || {
	echo 'deny-direct-event-write.sh: the hook input is not JSON; the call is allowed unchecked' >&2
	exit 0
}
[ "${tool}" = Bash ] || exit 0
command=$(printf '%s' "${input}" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0

# Prints "run" for each segment on stdin, one simple command per line, that
# runs event-write.sh. A function, as bash 3.2 can't parse a case inside $( ).
find_runs() {
	while IFS= read -r segment; do
		set -f
		# shellcheck disable=SC2086 # split into words on purpose
		set -- ${segment}
		# A shell's -c string is read as words of its own, so the loop goes round again.
		while :; do
			while [ $# -gt 0 ]; do
				case $1 in
					*=*) shift ;;
					env | exec | nice | nohup | time | command | sudo) shift ;;
					timeout) shift; [ $# -eq 0 ] || shift ;;
					*) break ;;
				esac
			done
			again=''
			case ${1-} in
				sh | bash | dash | zsh | */sh | */bash | */dash | */zsh | . | source)
					shift
					while [ $# -gt 0 ]; do
						case $1 in -c | -*c*) again=1; shift ;; -*) shift ;; *) break ;; esac
					done ;;
			esac
			[ -n "${again}" ] || break
		done
		[ $# -gt 0 ] || continue
		case $1 in
			*event-write.sh)
				shift
				[ "$*" = --help ] || [ "$*" = -h ] || echo run ;;
		esac
	done
}

# One segment per simple command; quotes and backslashes dropped before the
# words are read, and no word is globbed.
runs=$(printf '%s\n' "${command}" | tr ';&|()' '\n\n\n\n\n' | tr -d "\"'\\\\" | find_runs)

[ -n "${runs}" ] || exit 0
jq -n '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny",
	permissionDecisionReason: "crucible: events are written only by their component scripts, so a command that runs event-write.sh is denied; run the script for what you want to record."}}'
