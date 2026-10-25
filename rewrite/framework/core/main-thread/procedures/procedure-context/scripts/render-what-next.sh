#!/usr/bin/env sh
# Renders the "what next?" gate, asked once an effort's context is ready, so
# the main thread never hand-formats it. The title is fixed; its input is a
# plan file naming the context version and, after a grill, the grill file.
# Pipe its stdout into procedure-approval-gate's open-gate.sh.
# shellcheck source-path=SCRIPTDIR source-path=SCRIPTDIR/../../../../engine/crucible/scripts/lib
set -eu

readonly PROG='render-what-next.sh'
readonly PROCEDURE='procedure-context'
readonly RENDER_LIB='human-view'
# context-versions.sh's patterns are byte-wise only in the C locale.
LC_ALL=C
export LC_ALL

# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly RENDER_JQ='include "view";
def decisions: if . == 1 then "1 decision" else "\(.) decisions" end;
[status_line("decision"; "Decision needed · the context is ready: what next?"),
 (if $settled == null or $settled == 0 then "" else section("Settled"; [$settled | decisions]) end),
 data_section([["Context", $context]])]
| blocks
'

# Prints one line per problem of the slurped plan file; nothing when it is one
# object with a context path and, at most, a grill path.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly PLAN_CHECK_JQ='
def expected_plan: "expected one JSON object {\"context\": PATH[, \"grill\": PATH]}";
def path_problem($name):
	if (.[$name] | type) != "string" then "\($name) is a JSON \(.[$name] | type); expected a string holding an absolute path"
	elif .[$name] == "" then "\($name) is empty; expected an absolute path"
	else empty end;
if length != 1 then "the plan file holds \(length) JSON values; \(expected_plan)"
elif (.[0] | type) != "object" then "the plan file holds a JSON \(.[0] | type); \(expected_plan)"
else .[0]
	| ((keys - ["context", "grill"])[] | "\(tojson) is an unknown field; expected only context and grill"),
	  (if has("context") then path_problem("context") else "context missing; expected the absolute path of the context version" end),
	  (if has("grill") then path_problem("grill") else empty end)
end
'

# Prints plan field $name, or nothing when absent, plus a trailing "." so
# command substitution keeps a trailing line break; a NUL, which a shell
# variable cannot hold, becomes U+0001 so the control-character check sees it.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly FIELD_JQ='.[0][$name] // "" | explode | map(if . == 0 then 1 else . end) | implode + "."'

# Prints one line per problem of the slurped grill file; nothing when it is one
# object whose questions, when present, are an array (missing: no question).
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly GRILL_CHECK_JQ='
def expected_grill: "expected one JSON object whose questions, when present, are an array";
if length != 1 then "grill holds \(length) JSON values; \(expected_grill)"
elif (.[0] | type) != "object" then "grill holds a JSON \(.[0] | type); \(expected_grill)"
elif (.[0] | has("questions")) and (.[0].questions | type) != "array" then "grill questions is a JSON \(.[0].questions | type); \(expected_grill)"
else empty end
'

# Prints how many of the slurped grill's questions are settled.
readonly SETTLED_JQ='[(.[0].questions // [])[] | select(type == "object" and .status == "settled")] | length'

usage() {
	print_page <<EOF
usage: sh ${PROG} --plan-file PATH | sh <skills>/procedure-approval-gate/scripts/open-gate.sh --label what-next --effort FOLDER
       sh ${PROG} --help | -h

Prints the "what next?" gate, asking the human what follows a ready context,
as Markdown naming the context version. stdin and the context file are never
read, the plan file and the grill file only read; no file is written.

Options:
  --plan-file PATH    one JSON object, {"context": PATH, "grill": PATH}, no
                      other field, grill only after a grill:
                      context: the absolute path of an existing regular file,
                        not a symbolic link, named as a context version
                        (<YYYYMMDDTHHMMSS>-<4 lowercase hex>-v<N>.json), with
                        no control character
                      grill: the absolute path of an existing regular file,
                        not a symbolic link, with no control character,
                        holding one JSON object whose questions, when
                        present, are an array
  CLAUDE_CONFIG_DIR   the skills are in \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/skills

stdout on exit 0 only: the gate's Markdown, a fixed decision line, with
  a grill that settled any question its count of settled questions, and the
  context path, with no gate marker
stderr on exit 2: one "${PROG}: <what>; expected <x>[; try <y>]"
  line per problem (a usage error adds a "Try" line); a plan field is
  named context or grill
stderr on exits 1, 3, 5: "${PROG}: install:", a prefix no other exit
  prints; tell the human what it names to install, and stop

Exit codes:
  0  the gate printed; go on
  1  jq missing
  2  refused input; fix what stderr names and rerun once, else show the human stderr
  3  jq failed
  4  stdout closed before the gate was written, nothing on stderr; stop and
     show the exit code
  5  an install fault: a tool or skill file missing or failing; stderr names
     which

Dependencies: POSIX sh, jq 1.6+ (macOS: brew install jq; Linux: the
  distro's jq package), the ${RENDER_LIB} skill's view.jq and the crucible
  skill's scripts/lib/crucible-space.sh in the skills, context-versions.sh
  beside this script.
EOF
}

# Prints stdin with builtins only, so the help page prints with cat missing.
print_page() {
	while IFS= read -r page_line; do
		printf '%s\n' "${page_line}"
	done
}

warn() {
	printf '%s: %s\n' "${PROG}" "$1" >&2
}

# Prints an install or host fault (a missing or failing tool, never a problem
# of the input) with the "install:" prefix and exits $1.
install_fault() {
	warn "install: $2"
	exit "$1"
}

usage_error() {
	warn "$1"
	printf "Try '%s --help'.\n" "${PROG}" >&2
	exit 2
}

# Sets plan_file from the arguments.
parse_args() {
	plan_file=''
	while [ "$#" -gt 0 ]; do
		case $1 in
			--help | -h)
				usage
				exit 0
				;;
			--plan-file)
				[ "$#" -ge 2 ] && [ -n "$2" ] || usage_error '--plan-file needs a value; expected --plan-file PATH'
				plan_file=$2
				shift 2
				;;
			*) usage_error 'unknown argument; expected --plan-file PATH or --help' ;;
		esac
	done
	[ -n "${plan_file}" ] || usage_error '--plan-file PATH missing; expected --plan-file PATH naming the JSON file; stdin is not read'
}

script_dir() {
	case $0 in
		*/*) printf '%s' "${0%/*}" ;;
		*) printf '.' ;;
	esac
}

# Exits 5 unless file $1 is readable, naming skill $2 to install.
require_skill_file() {
	[ -f "$1" ] && [ -r "$1" ] ||
		install_fault 5 "$3 missing; expected $1; install the $2 skill"
}

# Sets render_lib_dir and sources the version naming rule, with the space
# rules it is built on.
load_dependencies() {
	command -v jq >/dev/null 2>&1 ||
		install_fault 1 'jq missing; expected jq 1.6+ on PATH; try installing jq (macOS: brew install jq; Linux: the distro'\''s jq package)'
	skills_dir="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/skills"
	render_lib_dir="${skills_dir}/${RENDER_LIB}"
	require_skill_file "${render_lib_dir}/view.jq" "${RENDER_LIB}" 'layout module'
	space_lib="${skills_dir}/crucible/scripts/lib/crucible-space.sh"
	require_skill_file "${space_lib}" crucible 'space rules'
	versions_lib="$(script_dir)/context-versions.sh"
	require_skill_file "${versions_lib}" "${PROCEDURE}" 'context version rule'
	# shellcheck source=crucible-space.sh
	. "${space_lib}"
	# shellcheck source=context-versions.sh
	. "${versions_lib}"
}

# Sets slurped to the plan file read into one array, so an empty file and
# several values are caught as one problem, or exits 2 when it is unreadable
# or not JSON.
read_plan() {
	[ -f "${plan_file}" ] && [ -r "${plan_file}" ] ||
		usage_error "plan file not readable: ${plan_file}; expected a readable JSON file"
	slurped=$(jq -s '.' "${plan_file}" </dev/null 2>/dev/null) || {
		warn 'the plan file is not valid JSON; expected one JSON object; try checking its quotes, commas and brackets, then rerun'
		exit 2
	}
}

# Prints problem lines $1, when any, to stderr and exits 2.
refuse_problems() {
	[ -n "$1" ] || return 0
	printf '%s\n' "$1" | while IFS= read -r problem; do warn "${problem}"; done
	exit 2
}

# Sets field_value to plan field $1, or empty when absent.
plan_field() {
	field_value=$(printf '%s' "${slurped}" | jq -r --arg name "$1" "${FIELD_JQ}") ||
		install_fault 3 'jq failed; expected jq 1.6+; try jq --version, then rerun'
	field_value=${field_value%.}
}

# Sets context and grill from the plan file, or exits 2 on a shape problem.
load_plan() {
	read_plan
	shape_problems=$(printf '%s' "${slurped}" | jq -r "${PLAN_CHECK_JQ}") ||
		install_fault 3 'jq failed; expected jq 1.6+; try jq --version, then rerun'
	refuse_problems "${shape_problems}"
	plan_field context
	context=${field_value}
	plan_field grill
	grill=${field_value}
}

# Prints one line per problem of the context path; nothing when it names a
# context version.
context_problems() {
	case ${context} in
		*[[:cntrl:]]*)
			printf '%s\n' 'context holds a control character (such as a line break or tab); expected one path on one line'
			return 0
			;;
		/*) ;;
		*) printf '%s\n' "context is not absolute: ${context}; expected an absolute path" ;;
	esac
	[ -f "${context}" ] && [ ! -L "${context}" ] ||
		printf '%s\n' "context is not a regular file, or is a symbolic link: ${context}; expected an existing context version file"
	# shellcheck disable=SC2310 # its status says whether the name is a version's
	context_version_of_name "${context##*/}" ||
		printf '%s\n' "context is not named as a context version: ${context##*/}; expected <YYYYMMDDTHHMMSS>-<4 lowercase hex>-v<N>.json, N from 1 with no leading zero"
}

# Prints one line per problem of the grill path; nothing when it names a
# readable regular file.
grill_path_problems() {
	case ${grill} in
		*[[:cntrl:]]*)
			printf '%s\n' 'grill holds a control character (such as a line break or tab); expected one path on one line'
			return 0
			;;
		/*) ;;
		*) printf '%s\n' "grill is not absolute: ${grill}; expected an absolute path" ;;
	esac
	if [ ! -f "${grill}" ] || [ -L "${grill}" ]; then
		printf '%s\n' "grill is not a regular file, or is a symbolic link: ${grill}; expected an existing grill file"
	elif [ ! -r "${grill}" ]; then
		printf '%s\n' "grill is not readable: ${grill}; expected a readable grill file"
	fi
}

# Appends problem lines $1, when any, to problems.
add_problems() {
	[ -n "$1" ] || return 0
	problems="${problems:+${problems}
}$1"
}

# Reads the grill file once and sets settled to its count of settled
# questions, or appends its problems to problems.
load_grill() {
	path_problems=$(grill_path_problems)
	if [ -n "${path_problems}" ]; then
		add_problems "${path_problems}"
		return 0
	fi
	grill_slurped=$(jq -s '.' "${grill}" </dev/null 2>/dev/null) || {
		add_problems "grill is not valid JSON: ${grill}; expected one JSON object whose questions, when present, are an array; try checking its quotes, commas and brackets"
		return 0
	}
	grill_found=$(printf '%s' "${grill_slurped}" | jq -r "${GRILL_CHECK_JQ}") ||
		install_fault 3 'jq failed; expected jq 1.6+; try jq --version, then rerun'
	if [ -n "${grill_found}" ]; then
		add_problems "${grill_found}"
		return 0
	fi
	settled=$(printf '%s' "${grill_slurped}" | jq "${SETTLED_JQ}") ||
		install_fault 3 'jq failed; expected jq 1.6+; try jq --version, then rerun'
}

parse_args "$@"
load_dependencies
load_plan
problems=$(context_problems)
settled=null
[ -z "${grill}" ] || load_grill
refuse_problems "${problems}"
view=$(jq -n -r -L "${render_lib_dir}" --arg context "${context}" --argjson settled "${settled}" "${RENDER_JQ}" </dev/null) ||
	install_fault 3 'jq failed; expected jq 1.6+; try jq --version, then rerun'
# Ignoring SIGPIPE turns a closed reader into a failed write this script can
# tell apart from a jq fault, rather than a silent kill.
trap '' PIPE
printf '%s\n' "${view}" 2>/dev/null || exit 4
