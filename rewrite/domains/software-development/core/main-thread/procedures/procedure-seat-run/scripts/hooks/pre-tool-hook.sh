#!/usr/bin/env sh
# Claude Code's PreToolUse hook on Write, Edit, MultiEdit and NotebookEdit.
# It reads the event once and hands it to each rule script in
# rules/pre-tool/, in name order; the first rule that denies the call
# decides it, and the call goes on when none does. It knows no rule itself.
# A fault lets the call go on, as a "fault:" line on stderr: a failing hook
# must never hold an agent. A rule that faults is passed over, so the rules
# after it still run.
set -eu
umask 077

readonly PROG='pre-tool-hook.sh'
readonly RULES_DIR='rules/pre-tool'
# A fault quotes at most this many bytes of a rule's first stderr line.
readonly MAX_QUOTE_BYTES=200
# A rule's stdout is one PreToolUse deny decision or nothing.
readonly DENY_JQ='select(type == "object")
| .hookSpecificOutput
| select(type == "object" and .hookEventName == "PreToolUse"
	and .permissionDecision == "deny" and (.permissionDecisionReason | type == "string"))
| {hookSpecificOutput: .}'
# The C locale keeps the shell byte-wise and the rules' name order fixed.
LC_ALL=C
export LC_ALL

usage() {
	cat <<EOF
usage: sh ${PROG} < pre-tool-use-input.json
       sh ${PROG} --help | -h

Claude Code's PreToolUse hook, matcher Write|Edit|MultiEdit|NotebookEdit.
Reads the event JSON on stdin once and runs each ${RULES_DIR}/*.sh beside
this script, in name order, as sh <rule> with the event on stdin. A rule
prints one PreToolUse deny decision to deny the call, or nothing, and exits
0. The first deny is printed and no later rule runs; with none the call
goes on, silently.

Faults let the call go on, each one "${PROG}: fault: <what>" on stderr:
stdin that is not one JSON object, jq missing, no rule script, and a rule
that exits non-zero or prints anything but a deny (that rule is passed
over; the next one runs).

stdout on a deny:
  {"hookSpecificOutput":{"hookEventName":"PreToolUse",
   "permissionDecision":"deny","permissionDecisionReason":"<the rule's>"}}
Writes nothing.

exit codes:
  0  done, whatever the outcome
  1  wrong command line (never 2: Claude Code reads 2 as a block)

needs: POSIX sh, jq 1.6+; what each rule's --help names
EOF
}

warn() {
	printf '%s: %s\n' "${PROG}" "$1" >&2
}

usage_error() {
	warn "$1"
	printf "Try 'sh %s --help'.\n" "${PROG}" >&2
	usage_failed=yes
	exit 1
}

# Prints $1 with each control character as "?", so a value can't split a line.
printable() {
	printf '%s' "$1" | tr '[:cntrl:]' '?'
}

parse_args() {
	while [ "$#" -gt 0 ]; do
		case $1 in
			-h | --help)
				usage
				exit 0
				;;
			*)
				shown_option=$(printable "$1")
				usage_error "unknown option: ${shown_option}; expected --help"
				;;
		esac
	done
}

# Lets the call go on.
allow() {
	exit 0
}

# Logs fault $1 and lets the call go on.
fault() {
	warn "fault: $1; the call goes on"
	allow
}

script_dir() {
	case $0 in
		*/*) printf '%s' "${0%/*}" ;;
		*) printf '.' ;;
	esac
}

# Keeps the event on stdin in work_dir/event, once it reads as one JSON object.
read_event() {
	command -v jq >/dev/null 2>&1 || fault 'jq not found; expected jq 1.6+ on PATH'
	cat >"${work_dir}/event" || fault 'stdin could not be read'
	jq -e 'type == "object"' "${work_dir}/event" >/dev/null 2>&1 ||
		fault 'stdin is not one JSON object; expected the PreToolUse event'
}

# Runs every rule in name order; prints the first deny and stops there.
run_rules() {
	rules_found=no
	for rule in "${own_dir}/${RULES_DIR}"/*.sh; do
		[ -f "${rule}" ] || continue
		rules_found=yes
		run_rule "${rule}"
		[ -z "${decision}" ] || {
			printf '%s\n' "${decision}"
			allow
		}
	done
	[ "${rules_found}" = yes ] || fault "no rule script in ${own_dir}/${RULES_DIR}; expected procedure-seat-run installed whole"
}

# Sets decision to rule $1's deny, or to nothing when it allows or faults; a
# fault is logged.
run_rule() {
	decision=''
	rule_name=${1##*/}
	rule_rc=0
	rule_out=$(sh "$1" <"${work_dir}/event" 2>"${work_dir}/stderr") || rule_rc=$?
	if [ "${rule_rc}" -ne 0 ]; then
		first_line=$(head -n 1 "${work_dir}/stderr" | cut -c "1-${MAX_QUOTE_BYTES}") || first_line=''
		shown_line=$(printable "${first_line}")
		warn "fault: ${rule_name} exit ${rule_rc}: ${shown_line}; the rule is passed over"
		return 0
	fi
	[ -n "${rule_out}" ] || return 0
	decision=$(printf '%s\n' "${rule_out}" | jq -c "${DENY_JQ}" 2>/dev/null) || decision=''
	case ${decision} in
		*'
'* | '')
			decision=''
			warn "fault: ${rule_name} printed something other than one PreToolUse deny; the rule is passed over"
			;;
		*) ;;
	esac
}

# An unexpected failure lets the call go on too, logged.
# shellcheck disable=SC2329 # invoked by the EXIT trap
on_exit() {
	exit_status=$?
	[ "${exit_status}" -eq 0 ] || [ "${usage_failed}" = yes ] || warn "fault: unexpected exit ${exit_status}; the call goes on"
	[ -z "${work_dir}" ] || rm -rf -- "${work_dir}"
	[ "${exit_status}" -eq 0 ] || [ "${usage_failed}" = yes ] || exit 0
}

work_dir='' usage_failed=no
trap on_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

parse_args "$@"
own_path=$(script_dir)
own_dir=$(cd -P -- "${own_path}" && pwd -P) || fault 'this script'\''s folder could not be entered'
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/crucible-pre-tool.XXXXXX") || {
	work_dir=''
	fault 'mktemp could not create a work folder; expected a writable TMPDIR'
}
read_event
run_rules
