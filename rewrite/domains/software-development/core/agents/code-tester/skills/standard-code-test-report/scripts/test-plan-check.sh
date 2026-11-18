#!/usr/bin/env sh
# Checks a tester's test plan before the stop hook records it. The shell
# checks the command line, the files and each behaviour's path:line file in
# the worktree; test-plan-check.jq checks the plan and words every problem
# as a repair the tester can make from that line alone, since the stop hook
# hands the tester nothing else. It changes nothing.
set -eu

readonly PROG='test-plan-check.sh'
readonly MODULE='test-plan-check'
readonly SKILL='standard-code-test-report'
# Bounds stderr so a refusal stays readable; one more line counts the rest.
readonly MAX_PROBLEMS=30
readonly newline='
'
readonly tab='	'
# The C locale keeps the shell byte-wise; jq reads the plan as UTF-8.
LC_ALL=C
export LC_ALL

# Prints the plan's well-formed behaviours[].at paths, one per line.
# shellcheck disable=SC2016 # the programs are single-quoted on purpose: their $ signs are jq's
readonly LOCATIONS_JQ='include "test-plan-check";
[$report | try fromjson] | if length == 1 then .[0] | plan_locations else empty end'

# Prints the problem lines, at most $max and one counting the rest.
# shellcheck disable=SC2016
readonly CHECK_JQ='include "test-plan-check";
plan_check($report; $files_text; $hint; $max)[]'

usage() {
	cat <<EOF
usage: sh ${PROG} --report FILE --worktree DIR
       sh ${PROG} --help | -h

Checks a tester's test plan; changes nothing, prints nothing on stdout.

--report FILE    absolute path of the plan: one JSON object, the seat's
                 draft <effort>/drafts/agents/<seat>/test-plan.json
--worktree DIR   absolute path of the build seat's worktree; every
                 behaviours[].at resolves against it

the plan: keys behaviours, add, modify, remove, fixtures, support,
untested, no_tests, baseline, run and blocker; a key or item key holding
null, [] or {} counts as left out. Ids: B- behaviours, T- add, M- modify,
R- remove, F- fixtures, N- untested, then a number from 1, unique per
prefix; guards, fixtures and covered_by name ids the plan gives. add.kind
new_test or new_rows (with rows); level e2e, integration or unit (why on
the last two); fixtures.source captured (with from), hand-written (with
why) or existing; covered_by a T- or M- id, <file>: <test name> or
nothing: <why>; blocker {kind: request_unclear or gate_red, detail}.
no_tests is given iff add, modify and remove are all empty. With neither
blocker nor no_tests, behaviours, baseline and run are required;
baseline pass or fail; a baseline fail goes with a gate_red blocker, or
with no blocker when modify or remove repairs the tests it ran. Texts are one line, with
no length cap; those the human reads (blocker.detail, no_tests,
behaviours text, add why and breaks_on, modify changes and keeps,
untested case, reason, risk and category) name no id like B-1. at is
path:line relative to the worktree, a line of a file in it. The shape is
set out in the ${SKILL} skill and references/test-plan.json;
where they differ, this check wins.

exit codes:
  0  the plan fits; nothing is printed
  2  wrong command line: a missing, repeated or unknown option, a path that
     is not absolute, or a --worktree that is no folder or can't be
     entered; fix the call
  3  the plan does not fit, is missing, empty, a folder or not a readable
     file, or is not one JSON object; each problem is one stderr line saying
     how to fix it (at most ${MAX_PROBLEMS}, then one counting the rest): fix
     the plan, check again
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
	report='' worktree=''
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
			*)
				shown_option=$(printable "$1")
				usage_error "unknown option: ${shown_option}; expected --report, --worktree or --help"
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
	[ -d "${worktree}" ] || usage_error "--worktree ${shown_worktree} is not a folder; expected the build seat's worktree"
	physical=$(cd -P -- "${worktree}" && pwd -P) ||
		usage_error "--worktree ${shown_worktree} can't be entered; expected a readable folder"
	worktree_prefix="${physical%/}/"
}

# Sets hint (where and in what shape the plan goes): the plan's own path,
# outside the worktree.
set_hint() {
	report_place=$(printable "${report}")
	# Resolved physically, so the path holds when the skill is installed through a link.
	scripts=$(script_dir)
	references=$(cd -P -- "${scripts}/../references" 2>/dev/null && pwd -P) ||
		die 4 "the ${SKILL} skill's references folder is not beside scripts/; expected the skill installed whole"
	shown_example=$(printable "${references}/test-plan.json")
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

# Refuses, with exit 3, a plan that is no readable, non-empty file.
check_plan_file() {
	require_absolute --report "${report}"
	[ -e "${report}" ] || die 3 "the plan is missing; ${hint}"
	[ ! -d "${report}" ] || die 3 "the plan path names a folder; remove the folder and ${hint}"
	[ -f "${report}" ] && [ -r "${report}" ] || die 3 "the plan is not a readable file; ${hint}"
	[ -s "${report}" ] || die 3 "the plan is empty; ${hint}"
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

# Sets files_text: one "status<TAB>lines<TAB>path" line per behaviours[].at path.
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

check_plan() {
	problems=$(jq -nr -L "${own_dir}" --rawfile report "${report}" \
		--arg files_text "${files_text}" --arg hint "${hint}" \
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
set_hint
load_dependencies
check_plan_file
look_up_locations
check_plan
