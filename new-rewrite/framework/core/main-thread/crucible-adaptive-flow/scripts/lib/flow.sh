# Shared by the flow scripts: the refusal line, a flow's name, the effort's
# events, the open-effort check and the writer.
# Sourced, so it sets no shell option; its names start with fl_.
# shellcheck shell=sh
# shellcheck disable=SC2154 # fl_prog is set by each sourcing script
# shellcheck disable=SC2034 # the fl_ values are read by the sourcing scripts

fl_here=$(cd -- "$(dirname -- "$0")/.." && pwd)
fl_lib="${fl_here}/lib"
fl_effort_state="${fl_here}/../../crucible-effort/scripts/main/effort-state.sh"
fl_writer="${fl_here}/../../crucible-events/scripts/internal/event-write.sh"

fl_refuse() {
	printf '%s: %s\n' "${fl_prog}" "$1" >&2
	exit 2
}

# Sets fl_effort from effort folder $1, refusing one that isn't.
fl_set_effort() {
	case $1 in /*) ;; *) fl_refuse '--effort must be an absolute folder' ;; esac
	[ -d "$1/events" ] || fl_refuse "$1 is not an effort folder"
	fl_effort=$1
}

# Sets fl_effort and fl_seq from a flow name $1, <effort folder>:<seq>.
fl_set_flow() {
	fl_seq=${1##*:}
	case ${fl_seq} in '' | *[!0-9]*) fl_refuse "--flow $1 must be <effort folder>:<seq>" ;; esac
	fl_seq=$(printf '%s' "${fl_seq}" | sed 's/^0*//')
	[ -n "${fl_seq}" ] || fl_refuse "--flow $1 names no flow"
	fl_set_effort "${1%:*}"
}

# Sets fl_all to every event of the effort as one JSON array, in seq order;
# exits 2 when the events can't be read.
fl_read_events() {
	fl_all=$(sh "${fl_here}/../../crucible-events/scripts/internal/events-read.sh" --effort "${fl_effort}") || exit 2
}

# Refuses unless the effort is open.
fl_require_open() {
	fl_state=$(sh "${fl_effort_state}" --effort "${fl_effort}") || exit 2
	[ "${fl_state}" = open ] || fl_refuse "the effort is ${fl_state}; flows change only while it's open"
}

# Writes event $1 with body file $2; prints the event's path, or exits with
# the writer's code.
fl_write() {
	sh "${fl_writer}" --effort "${fl_effort}" --type "$1" --by "${fl_prog}" --body-file "$2"
}
