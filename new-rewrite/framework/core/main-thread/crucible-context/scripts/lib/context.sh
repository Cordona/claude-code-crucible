# Shared by the context scripts: where an effort's context lives, the refusal
# line, the open-effort check, the context lock and the latest version.
# Sourced, so it sets no shell option; its names start with cx_.
# shellcheck shell=sh
# shellcheck disable=SC2154 # cx_prog is set by each sourcing script
# shellcheck disable=SC2034 # the cx_ values are read by the sourcing scripts

cx_here=$(cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1091 # the shared lock, in crucible-events
. "${cx_here}/../../crucible-events/scripts/lib/lock.sh"
. "${cx_here}/../../crucible-events/scripts/lib/sha256.sh"
. "${cx_here}/../../crucible-events/scripts/lib/atomic-write.sh"
cx_effort_state="${cx_here}/../../crucible-effort/scripts/effort-state.sh"
cx_writer="${cx_here}/../../crucible-events/scripts/event-write.sh"
cx_reader="${cx_here}/../../crucible-events/scripts/events-read.sh"
cx_gate_answer="${cx_here}/../../crucible-gate/scripts/gate-answer.sh"
cx_rules="${cx_here}/../events"

cx_refuse() {
	printf '%s: %s\n' "${cx_prog}" "$1" >&2
	exit 2
}

# Sets the context locations of effort $1, after refusing a non-absolute one:
# cx_dir (<effort>/context), cx_draft, cx_docs (the draft's docs folder),
# cx_entries (the pending entries file) and cx_events.
cx_set() {
	case $1 in /*) ;; *) cx_refuse '--effort must be an absolute folder' ;; esac
	[ -d "$1/events" ] || cx_refuse "$1 is not an effort folder"
	cx_effort=$1
	cx_dir="$1/context"
	cx_draft="${cx_dir}/draft"
	cx_docs="${cx_draft}/docs"
	cx_entries="${cx_draft}/entries.json"
	cx_events="$1/events"
}

# Refuses unless the effort is open.
cx_require_open() {
	cx_state=$(sh "${cx_effort_state}" --effort "${cx_effort}") || exit 2
	[ "${cx_state}" = open ] || cx_refuse "the effort is ${cx_state}; the context changes only while it's open"
}

# Takes the context lock, released on exit; refuses when it stays held.
cx_lock() {
	mkdir -p -- "${cx_dir}"
	cx_lockdir="${cx_dir}/.lock"
	lk_take "${cx_lockdir}" || cx_refuse 'the context lock stayed held; rerun'
	trap 'lk_release "${cx_lockdir}"' EXIT
	trap 'exit 129' HUP
	trap 'exit 130' INT
	trap 'exit 143' TERM
}

# Prints the newest context.cut event's path, or nothing.
cx_latest() {
	sh "${cx_reader}" --effort "${cx_effort}" --type context.cut --paths | tail -n 1
}


