#!/usr/bin/env sh
# Drops the empty keys from a developer's report before the stop hook checks
# it, so a stray "noticed": [] costs the developer no block. crucible's prune
# does the dropping. A file that holds no one JSON value is left for
# dev-report-check.sh to report; a report with nothing to drop is not touched.
# A change goes in place through a temp file beside the report, so the report
# is whole or unchanged.
set -eu
umask 077

readonly PROG='dev-report-prune.sh'
readonly CRUCIBLE_SKILL='crucible'
# The C locale keeps the shell byte-wise; jq reads the report as UTF-8.
LC_ALL=C
export LC_ALL

# Prints the pruned report, or nothing when pruning changes nothing.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly PRUNE_JQ='include "prune";
prune as $pruned | if $pruned == . then empty else $pruned end'

usage() {
	cat <<EOF
usage: sh ${PROG} --report FILE
       sh ${PROG} --help | -h

Drops every key whose value is null, [] or {} from a developer's report,
inner keys first, so a key left holding only empty keys goes too; array
items, false, 0 and "" stay. Prints nothing on stdout.

--report FILE  absolute path of the report

A file that is missing, empty, unreadable or not one JSON value is left
as it is; dev-report-check.sh reports it. A report with nothing to drop
is not rewritten. A changed report is written as jq prints it (2-space
indent) through a temp file beside it.

needs: POSIX sh, jq 1.6+ and prune.jq from the ${CRUCIBLE_SKILL} skill, in
${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/skills/${CRUCIBLE_SKILL}/scripts/lib

exit codes:
  0  done: the report was pruned, had nothing to drop, or is not one JSON
     value
  2  wrong command line: a missing, repeated or unknown option, or a path
     that is not absolute; fix the call
  4  jq or prune.jq is missing, jq failed, the report is a symbolic link,
     or the report could not be written
  129, 130, 143  stopped by HUP, INT or TERM; tell the human it was stopped,
     show the exit code, and stop
EOF
}

warn() {
	printf '%s: %s\n' "${PROG}" "$1" >&2
}

die() {
	warn "$2"
	exit "$1"
}

usage_error() {
	warn "$1"
	printf "Try 'sh %s --help'.\n" "${PROG}" >&2
	exit 2
}

# Prints $1 with each control character as "?", so a path can't split a stderr line.
printable() {
	printf '%s' "$1" | tr '[:cntrl:]' '?'
}

parse_args() {
	report=''
	while [ "$#" -gt 0 ]; do
		case $1 in
			-h | --help)
				usage
				exit 0
				;;
			--report)
				[ -n "${2-}" ] || usage_error '--report needs a value; expected --report FILE'
				[ -z "${report}" ] || usage_error '--report given twice; expected one'
				report=$2
				shift 2
				;;
			*)
				shown_option=$(printable "$1")
				usage_error "unknown option: ${shown_option}; expected --report or --help"
				;;
		esac
	done
	[ -n "${report}" ] || usage_error '--report missing; expected --report FILE'
	shown_report=$(printable "${report}")
	case ${report} in
		/*) ;;
		*) usage_error "--report ${shown_report} is not absolute; expected an absolute path" ;;
	esac
}

# Sets crucible_lib_dir (prune.jq, from the installed crucible skill).
load_dependencies() {
	command -v jq >/dev/null 2>&1 || die 4 'jq not found; expected jq 1.6+ on PATH'
	crucible_lib_dir="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/skills/${CRUCIBLE_SKILL}/scripts/lib"
	shown_lib_dir=$(printable "${crucible_lib_dir}")
	[ -f "${crucible_lib_dir}/prune.jq" ] && [ -r "${crucible_lib_dir}/prune.jq" ] ||
		die 4 "prune.jq not found in ${shown_lib_dir}; expected the ${CRUCIBLE_SKILL} skill installed"
}

# Exits 0, changing nothing, unless the report is a readable file holding one
# JSON value; refuses a link, since the write would replace the link itself.
require_one_json_value() {
	[ ! -L "${report}" ] || die 4 "--report ${shown_report} is a symbolic link; expected the report file itself"
	[ -f "${report}" ] && [ -r "${report}" ] && [ -s "${report}" ] || exit 0
	values=$(jq -s 'length' "${report}" 2>/dev/null) || exit 0
	[ "${values}" = 1 ] || exit 0
}

# Writes the pruned report to a temp file beside the report and moves it over
# the report; leaves the report untouched when pruning changes nothing.
prune_report() {
	report_dir=${report%/*}
	[ -n "${report_dir}" ] || report_dir=/
	temp_file=$(mktemp "${report_dir%/}/.${report##*/}.XXXXXX" 2>/dev/null) ||
		die 4 "could not create a temp file beside ${shown_report}; expected a writable folder"
	jq -L "${crucible_lib_dir}" "${PRUNE_JQ}" "${report}" >"${temp_file}" ||
		die 4 "jq failed; expected jq 1.6+ and prune.jq in ${shown_lib_dir}"
	[ -s "${temp_file}" ] || return 0
	mv -f -- "${temp_file}" "${report}" || die 4 "could not replace ${shown_report}"
	temp_file=''
}

# shellcheck disable=SC2329 # invoked by the EXIT trap
on_exit() {
	[ -z "${temp_file}" ] || rm -f -- "${temp_file}"
}

temp_file=''
trap on_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

parse_args "$@"
load_dependencies
require_one_json_value
prune_report
