#!/usr/bin/env sh
# Checks a developer's BUILD report before the stop hook commits it. The
# shell checks the command line, the files and each path:line's file in the
# worktree; dev-report-check.jq checks the report and words every problem as
# a repair the developer can make from that line alone, since the stop hook
# hands the developer nothing else. It changes nothing.
set -eu

readonly PROG='dev-report-check.sh'
readonly MODULE='dev-report-check'
readonly SKILL='standard-code-development-report'
# Bounds stderr so a refusal stays readable; one more line counts the rest.
readonly MAX_PROBLEMS=30
readonly newline='
'
readonly tab='	'
# The C locale keeps the shell byte-wise; jq reads the report as UTF-8.
LC_ALL=C
export LC_ALL

# Prints the report's well-formed path:line paths, one per line.
# shellcheck disable=SC2016 # the programs are single-quoted on purpose: their $ signs are jq's
readonly LOCATIONS_JQ='include "dev-report-check";
[$report | try fromjson] | if length == 1 then .[0] | report_locations else empty end'

# Prints the problem lines, at most $max and one counting the rest.
# shellcheck disable=SC2016
readonly CHECK_JQ='include "dev-report-check";
report_check($report; $round; $chosen_text; $files_text; $hint; $max)[]'

usage() {
	cat <<EOF
usage: sh ${PROG} --report FILE --worktree DIR [--chosen FILE]
       sh ${PROG} --help | -h

Checks a developer's BUILD report; changes nothing, prints nothing on stdout.

--report FILE    absolute path of the report: one JSON object
--worktree DIR   absolute path of the developer's worktree; every path:line
                 in the report resolves against it
--chosen FILE    absolute path of a text file, one chosen concern id per
                 line, blank lines ignored. Given: a fix round, whose answers
                 hold exactly these ids. Absent: an iteration, no answers.

the report: summary (one line, at most 56 characters) and verification (at
least one gate) are required; deviations, decisions, noticed, security
({kind, at, text}, kind secret or instruction), open (at most 8 items) and
blockers are optional; answers only in a fix round. Every text
is one line of at most 200 characters; no value is null, [] or {}; a
path:line is relative to the worktree and names a line of a file in it.
The shape is set out in the ${SKILL} skill's SKILL.md,
references/report-iteration.json and references/report-fix-round.json;
where they differ, this check wins.

exit codes:
  0  the report fits; nothing is printed
  2  wrong command line: a missing, repeated or unknown option, a path that
     is not absolute, a --worktree that is no folder or can't be entered,
     or a --chosen file that is missing, unreadable or holds no id; fix the
     call
  3  the report does not fit, is missing, empty, a folder or not a readable
     file, or is not one JSON object; each problem is one stderr line saying
     how to fix it (at most ${MAX_PROBLEMS}, then one counting the rest): fix
     the report, check again
  4  jq is missing or failed, ${MODULE}.jq is not beside
     ${PROG}, or the skill's references folder is not beside
     scripts/; install jq 1.6+ and keep the ${SKILL} skill whole

needs: POSIX sh, awk, jq 1.6+
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

# Sets $option_value from "$1 $2", refusing a repeat or a missing value.
take_value() {
	[ -n "$3" ] || usage_error "$1 needs a value; expected $1 $4"
	[ -z "$2" ] || usage_error "$1 given twice; expected one"
	option_value=$3
}

parse_args() {
	report='' worktree='' chosen=''
	while [ "$#" -gt 0 ]; do
		case $1 in
			-h | --help)
				usage
				exit 0
				;;
			--report)
				take_value "$1" "${report}" "${2-}" FILE
				report=${option_value}
				;;
			--worktree)
				take_value "$1" "${worktree}" "${2-}" DIR
				worktree=${option_value}
				;;
			--chosen)
				take_value "$1" "${chosen}" "${2-}" FILE
				chosen=${option_value}
				;;
			*)
				shown_option=$(printable "$1")
				usage_error "unknown option: ${shown_option}; expected --report, --worktree, --chosen or --help"
				;;
		esac
		shift 2
	done
	[ -n "${report}" ] || usage_error '--report missing; expected --report FILE'
	[ -n "${worktree}" ] || usage_error '--worktree missing; expected --worktree DIR'
}

# Refuses option $1 whose path $2 is not absolute.
require_absolute() {
	case $2 in
		/*) ;;
		*)
			shown_path=$(printable "$2")
			usage_error "$1 ${shown_path} is not absolute; expected an absolute path"
			;;
	esac
}

# Sets worktree_prefix: the worktree's physical path, ending in one /.
check_worktree() {
	require_absolute --worktree "${worktree}"
	shown_worktree=$(printable "${worktree}")
	[ -d "${worktree}" ] || usage_error "--worktree ${shown_worktree} is not a folder; expected the developer's worktree"
	physical=$(cd -P -- "${worktree}" && pwd -P) ||
		usage_error "--worktree ${shown_worktree} can't be entered; expected a readable folder"
	worktree_prefix="${physical%/}/"
}

# Sets round, chosen_file and hint (where and in what shape the report goes).
check_chosen() {
	if [ -z "${chosen}" ]; then
		round=first chosen_file=/dev/null example=report-iteration.json
	else
		require_absolute --chosen "${chosen}"
		shown_chosen=$(printable "${chosen}")
		[ -f "${chosen}" ] && [ -r "${chosen}" ] ||
			usage_error "--chosen ${shown_chosen} is not a readable file; expected the chosen ids, one per line"
		grep -q '[^[:space:]]' "${chosen}" ||
			usage_error "--chosen ${shown_chosen} holds no id; expected the chosen ids, one per line"
		round=fix chosen_file=${chosen} example=report-fix-round.json
	fi
	case ${report} in
		"${worktree_prefix}"*) report_place=${report#"${worktree_prefix}"} ;;
		"${worktree%/}/"*) report_place=${report#"${worktree%/}/"} ;;
		*) report_place='.crucible-effort/reports/<slot>/<build or test>-iteration-<N>.json' ;;
	esac
	report_place=$(printable "${report_place}")
	# Resolved physically, so the path holds when the skill is installed through a link.
	scripts=$(script_dir)
	references=$(cd -P -- "${scripts}/../references" 2>/dev/null && pwd -P) ||
		die 4 "the ${SKILL} skill's references folder is not beside scripts/; expected the skill installed whole"
	shown_example=$(printable "${references}/${example}")
	hint="write it to ${report_place} as one JSON object shaped like ${shown_example}"
}

script_dir() {
	case $0 in
		*/*) printf '%s' "${0%/*}" ;;
		*) printf '.' ;;
	esac
}

load_dependencies() {
	command -v jq >/dev/null 2>&1 || die 4 'jq not found; expected jq 1.6+ on PATH'
	own_dir=$(script_dir)
	[ -f "${own_dir}/${MODULE}.jq" ] || die 4 "${MODULE}.jq not found beside ${PROG}; expected both in one folder"
}

# Refuses, with exit 3, a report that is no readable, non-empty file.
check_report_file() {
	require_absolute --report "${report}"
	[ -e "${report}" ] || die 3 "the report is missing; ${hint}"
	[ ! -d "${report}" ] || die 3 "the report path names a folder; remove the folder and ${hint}"
	[ -f "${report}" ] && [ -r "${report}" ] || die 3 "the report is not a readable file; ${hint}"
	[ -s "${report}" ] || die 3 "the report is empty; ${hint}"
}

# Prints "status<TAB>lines" for worktree path $1: ok and its line count, or
# missing, folder, link, special, outside or unreadable and 0.
file_status() {
	target="${worktree_prefix}$1"
	# The file's folder with every link resolved, so a linked folder can't lead out.
	folder=$(cd -P -- "${target%/*}" 2>/dev/null && pwd -P) || folder=''
	case "${folder%/}/" in
		"${worktree_prefix}"*) inside=yes ;;
		*) inside=no ;;
	esac
	if [ -L "${target}" ]; then
		printf 'link%s0' "${tab}"
	elif [ ! -e "${target}" ]; then
		printf 'missing%s0' "${tab}"
	elif [ -d "${target}" ]; then
		printf 'folder%s0' "${tab}"
	elif [ ! -f "${target}" ]; then
		printf 'special%s0' "${tab}"
	elif [ "${inside}" = no ]; then
		printf 'outside%s0' "${tab}"
	elif [ ! -r "${target}" ]; then
		printf 'unreadable%s0' "${tab}"
	else
		# awk counts a last line that lacks its newline, as an editor shows it.
		lines=$(awk 'END { print NR }' "${target}") || lines=''
		if [ -n "${lines}" ]; then
			printf 'ok%s%s' "${tab}" "${lines}"
		else
			printf 'unreadable%s0' "${tab}"
		fi
	fi
}

# Sets files_text: one "status<TAB>lines<TAB>path" line per path:line path.
look_up_locations() {
	locations=$(jq -nr -L "${own_dir}" --rawfile report "${report}" "${LOCATIONS_JQ}") ||
		die 4 "jq failed; expected jq 1.6+ and ${MODULE}.jq beside ${PROG}"
	files_text=''
	[ -n "${locations}" ] || return 0
	while IFS= read -r path; do
		files_text="${files_text}$(file_status "${path}")${tab}${path}${newline}"
	done <<EOF
${locations}
EOF
}

check_report() {
	problems=$(jq -nr -L "${own_dir}" --rawfile report "${report}" --rawfile chosen_text "${chosen_file}" \
		--arg round "${round}" --arg files_text "${files_text}" --arg hint "${hint}" \
		--argjson max "${MAX_PROBLEMS}" "${CHECK_JQ}") ||
		die 4 "jq failed; expected jq 1.6+ and ${MODULE}.jq beside ${PROG}"
	[ -n "${problems}" ] || return 0
	while IFS= read -r problem; do
		warn "${problem}"
	done <<EOF
${problems}
EOF
	exit 3
}

parse_args "$@"
check_worktree
check_chosen
load_dependencies
check_report_file
look_up_locations
check_report
