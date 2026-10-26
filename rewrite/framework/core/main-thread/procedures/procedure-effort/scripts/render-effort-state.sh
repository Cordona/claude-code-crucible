#!/usr/bin/env sh
# Renders the views of an effort's state for the human, from effort.sh state
# and the state items it names, so the main thread never hand-formats them.
# shellcheck source-path=SCRIPTDIR
set -eu

readonly PROG='render-effort-state.sh'
readonly RENDER_LIB='human-view'
readonly CRUCIBLE_SKILL='crucible'
readonly KIND='states'
# Bounds stderr so a fault naming broken items stays readable; the rest is counted.
readonly MAX_PROBLEMS=20

# Prints the view of $command from the $count items passed as $ARGS.named
# pairs p<n> (the path) and i<n> (its text), oldest first, once each passes
# effort-state-validator.jq; else a "!" line and one "<path>: <problem>" line
# per problem. The program is single-quoted on purpose: its $ signs are jq's.
# shellcheck disable=SC2016
readonly VIEW_JQ='include "effort-state-validator";
include "view";
include "paths";
# Open and completed need nothing from the human; paused and dropped leave
# the effort waiting on them.
def state_light: {open: "done", completed: "done", paused: "attention", dropped: "attention"}[.];
def changed_view($items):
	$items[-1] as $newest
	| (if $newest | has("from") | not then "started" elif $newest.state == "open" then "reopened" else $newest.state end) as $word
	| "\(status_line(if $word == "started" or $word == "reopened" then "done" else $newest.state | state_light end; "Effort \($word) · \($name | code_span):")) \($folder | path_text)";
def status_view($items):
	($items[-1].state // "open") as $state
	| [status_line($state | state_light; "Effort · \($name | code_span)"; $state),
	   section("History"; if ($items | length) == 0 then ["open · since \($id_time)"]
		else $items | map("\(.state) · \(.at[0:10]) \(.at[11:16]) UTC") end),
	   ($folder | path_text)]
	| blocks;

$ARGS.named as $named
| [range(0; $count) | {path: $named["p\(.)"], parsed: [$named["i\(.)"] | try fromjson]}] as $read
| [$read[] | .path as $path
	| if (.parsed | length) == 0 then "is not one JSON value; expected a state item effort.sh writes" else .parsed[0] | effort_state_item_problems end
	| "\($path): \(.)"] as $problems
| if ($problems | length) > 0 then "!", $problems[:$max][],
	(if ($problems | length) > $max then "\($problems | length) problems, showing \($max)" else empty end)
  else [$read[].parsed[0]] as $items
	| if $command == "changed" then changed_view($items)
	  else status_view($items) end
  end'

usage() {
	cat <<EOF
usage: sh ${PROG} changed --effort FOLDER
       sh ${PROG} status --effort FOLDER
       sh ${PROG} --help | -h

Prints one view of an effort's state for the human, as Markdown. stdin is
never read; no file is written.

Commands:
  changed    the line after a state change, from the effort's newest state
             item
  status     the effort's state and its history, oldest first

Options:
  --effort FOLDER  an effort folder directly in <space>/efforts/, absolute,
                   as effort.sh start printed it
  CRUCIBLE_HOME    the space; default \$HOME/.crucible
  CLAUDE_CONFIG_DIR  holds the skills, in its skills/; default \$HOME/.claude

stdout on exit 0 only: the view's Markdown, to relay word for word
stderr on exit 2: one "${PROG}: <what>; expected <x>" line per
  problem (a usage error adds a "Try" line)

Exit codes:
  0  the view printed; go on
  1  jq missing; show the human stderr and exit code; go on when the change
     it shows is already written, else stop
  2  refused input; show the human stderr and exit code; go on when the
     change it shows is already written, else stop
  3  jq failed on valid input; show the human stderr and exit code; go on
     when the change it shows is already written, else stop
  4  stdout closed before the view was written, nothing on stderr; show the
     human stderr and exit code; go on when the change it shows is already
     written, else stop
  5  an install fault: a tool or skill file missing or failing, stderr names
     which; show the human stderr and exit code; go on when the change it
     shows is already written, else stop
  6  the effort's folder or state items are unusable; show the human stderr
     and exit code; go on when the change it shows is already written, else
     stop

Dependencies: POSIX sh, cat, jq 1.6+ (macOS: brew install jq; Linux: the
  distro's jq package); in the skills: the ${RENDER_LIB}
  skill's view.jq and paths.jq, the ${CRUCIBLE_SKILL} skill's
  scripts/lib/crucible-space.sh; effort.sh and effort-state-validator.jq
  beside this script.
EOF
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

refused() {
	warn "$1"
	exit 2
}

state_fault() {
	warn "$1"
	exit 6
}

# Sets command and effort from the arguments; exits 2 on any other.
parse_args() {
	[ "$#" -gt 0 ] || {
		usage >&2
		exit 2
	}
	case $1 in
		--help | -h)
			usage
			exit 0
			;;
		changed | status) command=$1 ;;
		*) usage_error 'unknown command; expected changed, status or --help' ;;
	esac
	shift
	effort=''
	while [ "$#" -gt 0 ]; do
		[ "$#" -ge 2 ] || usage_error "$1 needs a value; expected $1 VALUE"
		case $1 in
			--effort)
				[ -z "${effort}" ] || usage_error '--effort given twice; expected it once'
				effort=$2
				;;
			*) usage_error "unknown option for ${command}; expected --effort or --help" ;;
		esac
		shift 2
	done
	[ -n "${effort}" ] || usage_error "--effort missing; expected ${command} --effort FOLDER"
}

script_dir() {
	case $0 in
		*/*) printf '%s' "${0%/*}" ;;
		*) printf '.' ;;
	esac
}

# Exits 5 unless file $1, named $2, is readable; $3 is the skill to install.
require_file() {
	[ -f "$1" ] && [ -r "$1" ] || install_fault 5 "$2 missing; expected $1; install the $3 skill"
}

# Sets own_dir and render_lib_dir and sources the space rules, or exits 1 or 5.
load_dependencies() {
	command -v jq >/dev/null 2>&1 ||
		install_fault 1 'jq missing; expected jq 1.6+ on PATH; try installing jq (macOS: brew install jq; Linux: the distro'\''s jq package)'
	skills_dir="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/skills"
	own_dir=$(script_dir)
	require_file "${own_dir}/effort-state-validator.jq" 'state item shape' 'procedure-effort'
	require_file "${own_dir}/effort.sh" 'effort.sh' 'procedure-effort'
	render_lib_dir="${skills_dir}/${RENDER_LIB}"
	require_file "${render_lib_dir}/view.jq" 'layout module' "${RENDER_LIB}"
	require_file "${render_lib_dir}/paths.jq" 'path module' "${RENDER_LIB}"
	space_lib="${skills_dir}/${CRUCIBLE_SKILL}/scripts/lib/crucible-space.sh"
	require_file "${space_lib}" 'space rules' "${CRUCIBLE_SKILL}"
	# shellcheck source=../../../../engine/crucible/scripts/lib/crucible-space.sh
	. "${space_lib}"
}

# Sets effort to --effort without trailing slashes and name to its NAME once
# it names an effort folder of the space; exits 2 when the value breaks the
# rule, 6 when the folder is missing or unusable.
check_effort() {
	case ${effort} in
		*[[:cntrl:]]*) refused '--effort holds a control character; expected the effort folder effort.sh start printed' ;;
		*) ;;
	esac
	# shellcheck disable=SC2310 # its status says whether the space is usable; the fault is read below
	if ! crucible_resolve_root; then
		[ "${crucible_root_fault}" != usage ] || refused "${crucible_root_problem}"
		state_fault "${crucible_root_problem}"
	fi
	# shellcheck disable=SC2310 # its status says whether the folder passed; the fault is read below
	if ! crucible_check_effort_folder "${effort}"; then
		[ "${crucible_effort_fault}" = space ] || refused "${crucible_effort_refusal}"
		state_fault "${crucible_effort_refusal}"
	fi
	effort=${crucible_effort}
	# shellcheck disable=SC2310 # the folder passed the check, so its name splits
	crucible_is_effort_name "${effort##*/}" || true
	name=${crucible_name_rest}
	id_stamp=${crucible_name_id%-*}
}

# Sets item_lines to the effort's state items, one path
# per line, oldest first, as effort.sh state lists them.
read_items() {
	if state_out=$(sh "${own_dir}/effort.sh" state --effort "${effort}" </dev/null); then
		state_status=0
	else
		state_status=$?
	fi
	case ${state_status} in
		0) ;;
		2) exit 2 ;;
		4) state_fault "effort.sh state cannot read the effort's state (its stderr is above); expected readable state items; check them by hand" ;;
		*) install_fault 5 "effort.sh state failed with exit ${state_status} (its stderr is above); expected exit 0; try reinstalling procedure-effort" ;;
	esac
	while IFS= read -r state_line; do
		case ${state_line} in
			"ITEM: ${effort}/${KIND}/"*.json)
				item_lines="${item_lines}${state_line#ITEM: }
"
				;;
			'STATE: '*) ;;
			*) install_fault 5 'effort.sh state printed a line that is not STATE or ITEM of this effort; expected its contract; try reinstalling procedure-effort' ;;
		esac
	done <<EOF
${state_out}
EOF
	[ "${command}" != changed ] || [ -n "${item_lines}" ] ||
		refused "--effort ${effort} has no state item; expected changed after effort.sh start or a state change"
}

# Sets view to VIEW_JQ's output over the items of item_lines, passed as
# named pairs p<n> (the path) and i<n> (its text), or exits 6 naming the items
# that break the item shape.
render_view() {
	set --
	item_count=0
	while IFS= read -r item_path; do
		[ -n "${item_path}" ] || continue
		set -- "$@" --arg "p${item_count}" "${item_path}" --rawfile "i${item_count}" "${item_path}"
		item_count=$((item_count + 1))
	done <<EOF
${item_lines}
EOF
	view=$(jq -n -r -L "${own_dir}" -L "${render_lib_dir}" --arg command "${command}" --arg name "${name}" \
		--arg folder "${effort}" --arg id_time "${id_time}" --argjson count "${item_count}" \
		--argjson max "${MAX_PROBLEMS}" "$@" "${VIEW_JQ}" </dev/null) ||
		install_fault 3 'jq failed on valid input; expected jq 1.6+; try jq --version, then rerun'
	case ${view} in
		'!'*) ;;
		*) return 0 ;;
	esac
	while IFS= read -r problem; do
		[ "${problem}" = '!' ] || warn "${problem}"
	done <<EOF
${view}
EOF
	state_fault 'a state item is broken (named above); expected the items effort.sh writes; check them by hand'
}

# Sets id_time to the effort ID's local time, as stored, YYYY-MM-DD HH:MM:
# what status shows for an effort with no state item.
set_id_time() {
	[ -n "${id_stamp}" ] || return 0
	id_date=${id_stamp%T*} id_clock=${id_stamp#*T}
	month_day=${id_date#????} minutes_seconds=${id_clock#??}
	id_time="${id_date%????}-${month_day%??}-${month_day#??} ${id_clock%????}:${minutes_seconds%??}"
}

# Prints the view and a newline, or exits 4 when stdout is closed.
print_view() {
	[ -n "${view}" ] || return 0
	# Ignoring SIGPIPE turns a closed reader into a failed write this script
	# can tell apart from a jq fault, rather than a silent kill.
	trap '' PIPE
	printf '%s\n' "${view}" 2>/dev/null || exit 4
}

parse_args "$@"
load_dependencies
name='' id_stamp='' id_time='' item_lines=''
check_effort
read_items
set_id_time
render_view
print_view
