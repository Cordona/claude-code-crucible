#!/usr/bin/env sh
# Shows the cards of an effort's state for the human, from effort.sh state
# and the effort.* events it names, so the main thread never hand-formats them.
# views/effort-changed.jq and views/effort-status.jq lay them out and
# human-view's show.sh prints them, recording each as owed.
# shellcheck source-path=SCRIPTDIR
set -eu

readonly PROG='render-effort-state.sh'
readonly VIEW_LIB='human-view'
readonly SHOW='scripts/show.sh'
readonly RENDER_LIB='scripts/lib/render.sh'
readonly CRUCIBLE_SKILL='crucible'

# Prints the cards' data, {name, folder, items}, from the effort.* events read
# from stdin as one array, oldest first, each item {state, from?, at}. The
# program is single-quoted on purpose: its $ signs are jq's.
# shellcheck disable=SC2016
readonly VIEW_DATA_JQ='include "effort-state-validator";
{name: $name, folder: $folder,
 items: [.[] | {state: (effort_type_states[.type] // "unknown"), at} + (if .body.from then {from: .body.from} else {} end)]}'

usage() {
	print_block <<EOF
usage: sh ${PROG} changed --effort FOLDER
       sh ${PROG} status --effort FOLDER
       sh ${PROG} --help | -h

Prints one card of an effort's state for the human, as Markdown, through
${VIEW_LIB}'s show.sh view, which records it as owed this session.

Commands:
  changed    the line after an effort started or its state changed, from
             the effort's newest effort.* event
  status     the effort's state and its history, oldest first

Options:
  --effort FOLDER  an effort folder directly in <space>/efforts/, absolute,
                   as effort.sh start printed it
  CRUCIBLE_HOME    the space; default \$HOME/.crucible
  CLAUDE_CONFIG_DIR  holds the skills, in its skills/; default \$HOME/.claude
  CLAUDE_CODE_SESSION_ID  the session the card is recorded in; unset: the
                   card is printed, nothing is recorded

stdout on exit 0 only: the card, rendered from views/effort-<command>.jq
stderr: lines to show the human, as printed, a show.sh line first

Exit codes:
  0  the view printed; go on
  1  an install fault (stderr names it); show the human stderr and the exit
     code; go on when the change it shows is already written, else stop
  2  refused input; show the human stderr and the exit code; go on when the
     change it shows is already written, else stop
  3  an install fault: jq or show.sh failed (stderr names it); show the
     human stderr and the exit code; go on when the change it shows is
     already written, else stop
  4  stdout closed before the view was written, nothing on stderr; show the
     human the exit code; go on when the change it shows is already written,
     else stop
  5  an install fault (stderr names it); show the human stderr and the exit
     code; go on when the change it shows is already written, else stop
  6  the effort cannot be shown (stderr names why); show the human stderr and
     the exit code; go on when the change it shows is already written, else
     stop

Dependencies: POSIX sh, jq 1.6+; in the skills: the ${VIEW_LIB}
  skill's ${SHOW} and ${RENDER_LIB}, the ${CRUCIBLE_SKILL} skill's
  scripts/lib/crucible-space.sh; effort.sh and effort-state-validator.jq
  beside this script, views/effort-changed.jq and views/effort-status.jq in
  this skill.
EOF
}

# Copies stdin to stdout with the shell alone, so --help needs no tool.
print_block() {
	while IFS= read -r line; do
		printf '%s\n' "${line}"
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
	[ "$#" -gt 0 ] || usage_error 'a command is missing; expected changed, status or --help'
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

# Sets own_dir, views_dir and show_script and sources the space rules, or
# exits 1 or 5.
load_dependencies() {
	command -v jq >/dev/null 2>&1 ||
		install_fault 1 'jq missing; expected jq 1.6+ on PATH; try installing jq (macOS: brew install jq; Linux: the distro'\''s jq package)'
	skills_dir="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/skills"
	own_dir=$(script_dir)
	require_file "${own_dir}/effort-state-validator.jq" 'effort states, moves and event types' 'procedure-effort'
	require_file "${own_dir}/effort.sh" 'effort.sh' 'procedure-effort'
	views_dir="${own_dir}/../views"
	render_lib="${skills_dir}/${VIEW_LIB}/${RENDER_LIB}"
	require_file "${render_lib}" 'card printer lib' "${VIEW_LIB}"
	# shellcheck source=../../../../engine/human-view/scripts/lib/render.sh
	. "${render_lib}"
	# shellcheck disable=SC2310 # its status is the answer; set -e is not relied on inside
	hv_check_printer "${skills_dir}/${VIEW_LIB}/scripts" "${views_dir}" "effort-${command}" || install_fault 5 "${hv_printer_problem}"
	show_script=${hv_show}
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
		*[[:cntrl:]]*) refused '--effort holds a control character; expected the effort folder effort.sh start printed; try the folder effort.sh path prints' ;;
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
}

# Sets item_lines to the effort's effort.* events, one path per line, oldest
# first, as effort.sh state lists them.
read_items() {
	if state_out=$(sh "${own_dir}/effort.sh" state --effort "${effort}" </dev/null); then
		state_status=0
	else
		state_status=$?
	fi
	case ${state_status} in
		0) ;;
		2) exit 2 ;;
		4) state_fault "effort.sh state cannot read the effort's state (its stderr is above); expected an effort with events; try another effort, or start a new one" ;;
		*) install_fault 5 "effort.sh state failed with exit ${state_status} (its stderr is above); expected exit 0; try reinstalling procedure-effort" ;;
	esac
	while IFS= read -r state_line; do
		case ${state_line} in
			"EVENT: ${effort}/events/"*.json)
				item_lines="${item_lines}${state_line#EVENT: }
"
				;;
			'STATE: '*) ;;
			*) install_fault 5 'effort.sh state printed a line that is not STATE or EVENT of this effort; expected its contract; try reinstalling procedure-effort' ;;
		esac
	done <<EOF
${state_out}
EOF
	[ -n "${item_lines}" ] ||
		state_fault "--effort ${effort} has no effort.* event; expected an effort effort.sh start made; try another effort, or start a new one"
}

# Sets view_data to VIEW_DATA_JQ's output over the events of item_lines.
build_view_data() {
	set --
	while IFS= read -r item_path; do
		[ -z "${item_path}" ] || set -- "$@" "${item_path}"
	done <<EOF
${item_lines}
EOF
	view_data=$(jq -s -c -L "${own_dir}" --arg name "${name}" --arg folder "${effort}" \
		"${VIEW_DATA_JQ}" "$@" </dev/null) ||
		install_fault 3 'jq failed on valid input; expected jq 1.6+; try jq --version, then rerun'
}

# Prints the card through show.sh view, recorded as owed for the effort; a
# closed stdout exits 4, a show.sh fault is an install fault.
show_card() {
	# shellcheck disable=SC2310 # its status names the fault; set -e is not relied on inside
	hv_show_card "${show_script}" "${views_dir}" "effort-${command}" "${effort}" "${view_data}" && return 0
	[ "${hv_render_status}" != 5 ] || install_fault 5 "${hv_render_problem}; expected the ${VIEW_LIB} skill installed whole"
	install_fault 3 "${hv_render_problem}; expected the card shown from views/effort-${command}.jq; try reinstalling procedure-effort and ${VIEW_LIB}"
}

parse_args "$@"
load_dependencies
name='' item_lines=''
check_effort
read_items
build_view_data
show_card
