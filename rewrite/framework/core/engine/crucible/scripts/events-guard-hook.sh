#!/usr/bin/env sh
# Claude Code's PreToolUse hook on Bash. It denies a Bash tool call whose
# command runs events.sh, from the main thread or an agent alike: events are
# written only by the scripts and hooks that own them, and their own calls to
# events.sh are child processes, never Bash tool calls, so they pass. The
# command text is untrusted: it is only parsed by jq, never run. It fails
# closed: whatever stops it before a decision denies the call.
set -eu

readonly PROG='events-guard-hook.sh'
# The reasons hold no " or \, so print_deny's literal fallback stays valid JSON.
readonly DENY_REASON='crucible: events are written only by their owning scripts, so a Bash command that runs events.sh is denied; run the script that owns the event instead.'
readonly NO_JQ_REASON='crucible: jq is not on PATH, so the events guard cannot check this Bash command and denies it; install jq 1.6+ (macOS: brew install jq; Linux: the distro'\''s jq), then rerun the command.'
readonly BAD_INPUT_REASON='crucible: the events guard could not read its hook input as a JSON object, so it denies the call; rerun it, and if this repeats, show the human this reason.'
readonly STOPPED_REASON='crucible: the events guard stopped before it decided, so it denies the call; rerun it, and if this repeats, show the human this reason.'
# shellcheck disable=SC2016 # $reason is jq's
readonly DENY_JQ='{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
# Splits the command into its simple commands, with quotes, backslashes and a
# $ opening a quote dropped, and denies when one runs events.sh: as the
# command word, after a shell interpreter
# (its -c string checked as a command), or after . or source; a redirect
# joined to a word is cut off before its name is read. A lone --help or -h
# only prints its contract, and passes. Leading assignments, redirects, shell
# keywords and the wrappers in $wrappers are skipped first, with the options
# each one takes a value for (timeout also drops its duration); command -v or
# -V only looks its name up, and passes. A word naming events.sh anywhere
# else (sed -n 1p events.sh, grep fault events.sh) is a read, and passes.
# A name read as a pattern ({..} any text, [..] one character, *, ?) that
# could match events.sh counts as events.sh.
# The program is single-quoted on purpose: its $ names are jq's.
# shellcheck disable=SC2016
readonly GUARD_JQ='
{
	env: ["-u", "-C"], exec: ["-a"], nice: ["-n"], timeout: ["-s", "-k"],
	sudo: ["-u", "-g", "-C", "-D", "-h", "-p", "-R", "-r", "-t", "-T", "-U"],
	xargs: ["-a", "-d", "-E", "-I", "-L", "-n", "-P", "-s"],
	time: ["-f", "-o"], command: [], nohup: [], builtin: [], eval: []
} as $wrappers
| def base: [splits("[<>]")][0] | split("/") | last;
def as_pattern:
	gsub("\\{[^}]*\\}"; "\u0001") | gsub("\\[[^]]*\\]"; "\u0002")
	| gsub("(?<c>[.+^$()|\\[\\]{}\\\\])"; "\\\(.c)")
	| gsub("\\*"; ".*") | gsub("\\?"; ".") | gsub("\u0001"; ".*") | gsub("\u0002"; ".");
def is_events: . == "events.sh" or (test("[*?{\\[]") and (as_pattern as $re | "events.sh" | test("^(?:" + $re + ")$")));
def help_only: . == ["--help"] or . == ["-h"];
def drop_options($valued):
	if length == 0 then .
	elif .[0] == "--" then .[1:]
	elif (.[0] | startswith("-")) and (.[0] | length) > 1 then
		(.[0] as $option | if any($valued[]; . == $option) then .[2:] else .[1:] end) | drop_options($valued)
	else . end;
def looks_up: length > 0 and (.[0] | test("^-[A-Za-z]+$")) and ((.[0] | test("[vV]")) or (.[1:] | looks_up));
def skip_redirect: if (.[0] | test("^[0-9]*[<>]+$")) then .[2:] else .[1:] end;
def strip_prefix:
	if length == 0 then .
	elif (.[0] | test("^[0-9]*[<>]")) then skip_redirect | strip_prefix
	elif (.[0] | base) == "command" and (.[1:] | looks_up) then []
	elif (.[0] | test("^[A-Za-z_][A-Za-z0-9_]*=")) then .[1:] | strip_prefix
	elif (.[0] as $w | any(["!", "{", "}", "if", "then", "else", "elif", "do", "while", "until"][]; . == $w)) then .[1:] | strip_prefix
	elif (.[0] | base) as $w | $wrappers | has($w) then
		(.[0] | base) as $w
		| .[1:] | drop_options($wrappers[$w])
		| if $w == "timeout" then .[1:] else . end
		| strip_prefix
	else . end;
def runs_file: (.[0] | ltrimstr("<") | base | is_events) and (.[1:] | help_only | not);
def runs_events:
	def interpreter_runs:
		if length == 0 then false
		elif (.[0] | test("^-[A-Za-z]*c[A-Za-z]*$")) then .[1:] | (if .[0] == "--" then .[1:] else . end) | runs_events
		elif (.[0] | test("^[-+][A-Za-z]*[oO]$")) or .[0] == "--rcfile" or .[0] == "--init-file" then .[2:] | interpreter_runs
		elif (.[0] | test("^[0-9]*>")) then skip_redirect | interpreter_runs
		elif (.[0] | test("^[-+]")) or .[0] == "<" then .[1:] | interpreter_runs
		else runs_file end;
	strip_prefix
	| if length == 0 then false
	else (.[0] | base) as $cmd
		| if $cmd | is_events then runs_file
		elif $cmd == "." or $cmd == "source" then (.[1] // "") | base | is_events
		elif any(["sh", "bash", "dash", "zsh", "ksh", "ash", "mksh", "yash"][]; . == $cmd) then .[1:] | interpreter_runs
		else false end
	end;
input
| if type == "object" then . else error("hook input is not an object") end
| select(.tool_name == "Bash")
| (.tool_input.command | strings)
| gsub("\\$[\"'"'"']"; "") | gsub("[\"'"'"'\\\\]"; "")
| select(any(splits("\\$\\(|[`;&|()\\n\\r]")
	| [splits("[ \\t]+") | select(. != "")]
	| runs_events; .))
| '"${DENY_JQ}"

usage() {
	cat <<EOF
usage: sh ${PROG} < pre-tool-use-input.json
       sh ${PROG} --help | -h

Claude Code's PreToolUse hook on Bash: denies a Bash tool call whose command
runs the crucible skill's events.sh, from the main thread or an agent. A
command that only reads, names or looks up the file (sed -n, grep, cat of
events.sh, command -v or -V), or runs it with a lone --help or -h, is
allowed, and so is every script that calls events.sh itself: that call is no
Bash tool call. It fails closed: with jq missing, input that is not a JSON
object, or any stop before a decision, it denies the call; with
"onFailure": "block" on its settings entry, a timeout blocks the call too.
Quotes, backslashes and a $ before a quote are dropped before names are
read; a command or script name whose part after the last / holds a pattern
({..} any text, [..] one character, *, ?) is denied when it could match
events.sh. It catches the plain and quoted names main or an agent would
write by mistake.
Not detected: a name the shell builds by expansion (braces around a path, a
parameter, a command substitution, an escape inside \$'..', and the like), a
run by indirection (a copy, a variable holding its path, a pipe, xargs or a
redirect placed before the shell word feeding its name or text to a shell,
as in <events.sh sh), behind a wrapper other than env, exec, nice, timeout,
sudo, xargs, time, command, nohup, builtin and eval, or behind an option it
doesn't know to take a separate value: a long wrapper one (sudo --user x),
or a shell one other than -o, +o, -O, +O (alone or ending a cluster),
--rcfile and --init-file.

stdin: the hook JSON (tool_name, tool_input.command); a tool_name other than
  Bash, or a command that is not a string, is allowed untouched
stdout on a deny (exit 0): one PreToolUse decision for Claude Code,
  {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"${DENY_REASON}"}}
  or, when it could not check the call, the same decision with a reason
  naming why
Writes nothing.

Exit codes:
  0  allowed; or denied by the decision on stdout, which Claude Code applies,
     giving Claude its reason
  1  wrong command line; Claude Code shows stderr, and blocks the call when
     the entry sets "onFailure": "block", else allows it

Dependencies:
  POSIX sh; jq 1.6+ (macOS: brew install jq; Linux: the distro's jq)
EOF
}

warn() {
	printf '%s: %s\n' "${PROG}" "$1" >&2
}

# Prints a deny with reason $1, built by jq, or as a fixed literal when jq
# can't run (every reason passed is a constant above).
print_deny() {
	jq -cn --arg reason "$1" "${DENY_JQ}" 2>/dev/null ||
		printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$1"
}

# The EXIT trap: any exit before a decision denies the call, with exit 0 so
# Claude Code reads the decision.
# shellcheck disable=SC2329 # called by name from the EXIT trap
deny_undecided() {
	if [ -n "${decided}" ]; then return 0; fi
	decided=1
	print_deny "${STOPPED_REASON}"
	exit 0
}

case $# in
	0) ;;
	*)
		case $1 in
			--help | -h)
				usage
				exit 0
				;;
			*)
				warn "unknown argument; expected none, or --help"
				printf "Try 'sh %s --help'.\n" "${PROG}" >&2
				# Never 2: Claude Code reads exit 2 as a block whatever the entry says.
				exit 1
				;;
		esac
		;;
esac

decided=''
trap deny_undecided EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if ! command -v jq >/dev/null 2>&1; then
	decided=1
	print_deny "${NO_JQ_REASON}"
	exit 0
fi
if decision=$(jq -cn --arg reason "${DENY_REASON}" "${GUARD_JQ}" 2>/dev/null); then
	decided=1
	[ -z "${decision}" ] || printf '%s\n' "${decision}"
	exit 0
fi
decided=1
print_deny "${BAD_INPUT_REASON}"
exit 0
