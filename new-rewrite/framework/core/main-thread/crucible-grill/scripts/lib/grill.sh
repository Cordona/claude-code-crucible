# Shared by the grill scripts: where grills live, the refusal line, the
# open-effort check, the lock, the shape check and the atomic write.
# Sourced, so it sets no shell option; its names start with gr_.
# shellcheck shell=sh
# shellcheck disable=SC2154 # gr_prog is set by each sourcing script
# shellcheck disable=SC2034 # the gr_ values are read by the sourcing scripts

gr_here=$(cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1091 # the shared lock, in crucible-events
. "${gr_here}/../../crucible-events/scripts/lib/lock.sh"
. "${gr_here}/../../crucible-events/scripts/lib/atomic-write.sh"
gr_effort_state="${gr_here}/../../crucible-effort/scripts/effort-state.sh"
gr_writer="${gr_here}/../../crucible-events/scripts/event-write.sh"
gr_reader="${gr_here}/../../crucible-events/scripts/events-read.sh"
gr_lib="${gr_here}/lib"

gr_refuse() {
	printf '%s: %s\n' "${gr_prog}" "$1" >&2
	exit 2
}

# Sets gr_effort and gr_dir (<effort>/grills) for effort folder $1.
gr_set_effort() {
	case $1 in /*) ;; *) gr_refuse '--effort must be an absolute folder' ;; esac
	[ -d "$1/events" ] || gr_refuse "$1 is not an effort folder"
	gr_effort=$1
	gr_dir="$1/grills"
}

# Sets gr_file, gr_effort and gr_dir from an open grill's draft path $1.
gr_set_grill() {
	case $1 in */grills/[1-9]*.json) ;; *) gr_refuse "$1 is not a grill draft (<effort>/grills/<n>.json)" ;; esac
	[ -f "$1" ] && [ ! -L "$1" ] || gr_refuse "$1 is not an open grill: it has ended, or never existed"
	gr_file=$1
	gr_set_effort "${1%/grills/*}"
}

# Refuses unless the effort is open.
gr_require_open() {
	gr_state=$(sh "${gr_effort_state}" --effort "${gr_effort}") || exit 2
	[ "${gr_state}" = open ] || gr_refuse "the effort is ${gr_state}; grills change only while it's open"
}

# Takes the effort's grill lock, released on exit; refuses when it stays held.
gr_lock() {
	mkdir -p -- "${gr_dir}"
	gr_lockdir="${gr_dir}/.lock"
	lk_take "${gr_lockdir}" || gr_refuse 'the grill lock stayed held; rerun'
	trap 'lk_release "${gr_lockdir}"' EXIT
	trap 'exit 129' HUP
	trap 'exit 130' INT
	trap 'exit 143' TERM
}

# Checks the grill JSON on stdin against the shape and writes it to file $1
# through a temp file beside it; refuses, writing nothing, when it doesn't fit.
gr_save() {
	gr_new=$(cat)
	gr_problems=$(printf '%s\n' "${gr_new}" | jq -r -L "${gr_lib}" 'include "grill-shape"; grill_problems' 2>&1) \
		|| gr_refuse "the grill can't be read: ${gr_problems}"
	[ -z "${gr_problems}" ] || gr_refuse "$(printf '%s' "${gr_problems}" | paste -sd '|' - | sed 's/|/; /g')"
	printf '%s\n' "${gr_new}" | aw_write "$1" || gr_refuse "$1 could not be written"
}
