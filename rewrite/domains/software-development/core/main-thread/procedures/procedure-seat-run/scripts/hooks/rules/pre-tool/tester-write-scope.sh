#!/usr/bin/env sh
# A rule of pre-tool-hook.sh: it denies a code-tester agent's Write, Edit,
# MultiEdit or NotebookEdit call to any file but a test file or test data, as
# write-scope.jq's in_scope("tester"; path) judges the target path relative
# to the git worktree it lies in. The path's folders that do not exist yet
# are taken as written, "." and ".." resolved by name; the ones that exist
# are resolved through their links. A path outside every git worktree (the
# mutation copy has no .git), and every other agent's call, is allowed.
set -eu

readonly PROG='tester-write-scope.sh'
readonly TESTER_AGENT='code-tester'
readonly ROLE='tester'
# From this folder to write-scope.jq.
readonly SCOPE_DIR='../../../seats'
readonly DENY_REASON='Production files are not yours to write: leave them unchanged. A production bug is a red test plus a production_bug blocker; a change outside the tests goes in open.'
# shellcheck disable=SC2016 # $reason is jq's
readonly DENY_JQ='{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
# Prints the target path and cwd of a tester's write call, one per line;
# nothing for any other call. A control character in either is an error.
# shellcheck disable=SC2016 # $agent is jq's
readonly FIELDS_JQ='if type != "object" then error("the event is not a JSON object")
elif .agent_type == $agent and (.tool_name | IN("Write", "Edit", "MultiEdit", "NotebookEdit")) then
	((.tool_input.file_path | strings) // (.tool_input.notebook_path | strings) // ""),
	((.cwd | strings) // "")
	| if test("[[:cntrl:]]") then error("a path holds a control character") else . end
else empty end'
# The C locale keeps the shell byte-wise; jq reads the JSON as UTF-8.
LC_ALL=C
export LC_ALL
GIT_OPTIONAL_LOCKS=0
GIT_TERMINAL_PROMPT=0
export GIT_OPTIONAL_LOCKS GIT_TERMINAL_PROMPT
unset GIT_DIR GIT_WORK_TREE

usage() {
	cat <<EOF
usage: sh ${PROG} < pre-tool-use-input.json
       sh ${PROG} --help | -h

A rule of pre-tool-hook.sh. Reads the PreToolUse event JSON on stdin. Goes
on only when agent_type is ${TESTER_AGENT} and tool_name is Write, Edit,
MultiEdit or NotebookEdit; the target is tool_input.file_path, else
tool_input.notebook_path, a relative one taken from cwd. git rev-parse
--show-toplevel, run in the target's nearest folder that exists, names its
worktree; the path relative to that worktree goes to in_scope("${ROLE}"; path)
of ../../../seats/write-scope.jq. Out of scope: the call is denied.
No target, or one outside every git worktree: allowed.

stdout on a deny: one PreToolUse decision whose permissionDecisionReason is
  "${DENY_REASON}"
  nothing otherwise. Writes nothing.

exit codes:
  0  decided: denied by the decision on stdout, or allowed
  1  wrong command line
  4  could not decide (stderr says why): jq or git missing, the event not
     a JSON object, a path holding a control character, write-scope.jq
     missing or failing

needs: POSIX sh, jq 1.6+, git; write-scope.jq at ${SCOPE_DIR}
EOF
}

warn() {
	printf '%s: %s\n' "${PROG}" "$1" >&2
}

# Names fault $1 on stderr and exits 4.
fault() {
	warn "$1"
	exit 4
}

parse_args() {
	[ "$#" -gt 0 ] || return 0
	case $1 in
		-h | --help)
			usage
			exit 0
			;;
		*)
			warn "unknown option; expected none, or --help"
			printf "Try 'sh %s --help'.\n" "${PROG}" >&2
			exit 1
			;;
	esac
}

script_dir() {
	case $0 in
		*/*) printf '%s' "${0%/*}" ;;
		*) printf '.' ;;
	esac
}

check_tools() {
	command -v jq >/dev/null 2>&1 || fault 'jq not found; expected jq 1.6+ on PATH'
	command -v git >/dev/null 2>&1 || fault 'git not found; expected git on PATH'
}

# Sets target and cwd from the event on stdin; any call but a tester's
# write is allowed here.
read_event() {
	fields=$(jq -r --arg agent "${TESTER_AGENT}" "${FIELDS_JQ}" 2>&1) ||
		fault "the event could not be read: ${fields%%
*}"
	[ -n "${fields}" ] || exit 0
	target='' cwd=''
	{
		IFS= read -r target || :
		IFS= read -r cwd || :
	} <<EOF
${fields}
EOF
	[ -n "${target}" ] || exit 0
	case ${target} in
		/*) ;;
		*) target="${cwd:-${PWD}}/${target}" ;;
	esac
	case ${target} in
		/*) ;;
		*) exit 0 ;;
	esac
}

# Sets existing to the target's nearest folder that exists and missing to
# the rest of the path below it.
split_existing() {
	existing=${target%/*}
	missing=${target##*/}
	while [ -n "${existing}" ] && [ ! -d "${existing}" ]; do
		missing="${existing##*/}/${missing}"
		existing=${existing%/*}
	done
	[ -n "${existing}" ] || existing=/
}

# Prints absolute path $1 with empty and "." segments dropped and each ".."
# taking off the segment before it.
normalize() {
	IFS=/
	set -f
	normalized=''
	# shellcheck disable=SC2086 # split on / on purpose; globbing is off
	for segment in $1; do
		case ${segment} in
			'' | .) ;;
			..) normalized=${normalized%/*} ;;
			*) normalized="${normalized}/${segment}" ;;
		esac
	done
	printf '%s' "${normalized:-/}"
}

# Sets relative to the target's path relative to its git worktree; a target
# outside every worktree is allowed.
find_relative() {
	top=$(git -c core.fsmonitor=false -C "${existing}" rev-parse --show-toplevel 2>/dev/null) || exit 0
	top=$(cd -P -- "${top}" 2>/dev/null && pwd -P) || exit 0
	existing=$(cd -P -- "${existing}" 2>/dev/null && pwd -P) || exit 0
	full=$(normalize "${existing}/${missing}")
	case ${full} in
		"${top}"/?*) relative=${full#"${top}"/} ;;
		*) exit 0 ;;
	esac
}

# Prints the deny when the tester may not write the relative path.
judge() {
	scope_dir=$(cd -P -- "${own_dir}/${SCOPE_DIR}" 2>/dev/null && pwd -P) ||
		fault "the seats folder ${SCOPE_DIR} is not beside ${own_dir}; expected procedure-seat-run installed whole"
	[ -f "${scope_dir}/write-scope.jq" ] || fault "${scope_dir}/write-scope.jq is missing; expected procedure-seat-run installed whole"
	in_scope=$(jq -nr -L "${scope_dir}" --arg role "${ROLE}" --arg path "${relative}" \
		'include "write-scope"; in_scope($role; $path)' 2>&1) ||
		fault "write-scope.jq failed: ${in_scope%%
*}"
	case ${in_scope} in
		true) ;;
		false) jq -nc --arg reason "${DENY_REASON}" "${DENY_JQ}" || fault 'jq could not build the deny' ;;
		*) fault "write-scope.jq printed ${in_scope}; expected true or false" ;;
	esac
}

parse_args "$@"
check_tools
own_path=$(script_dir)
own_dir=$(cd -P -- "${own_path}" && pwd -P) || fault 'this script'\''s folder could not be entered'
read_event
split_existing
find_relative
judge
