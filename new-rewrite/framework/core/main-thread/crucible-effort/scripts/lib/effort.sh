# Shared by the effort scripts: where efforts live, the event writer and
# rules they use, and an effort's current state read from its events.
# Sourced, so it sets no shell option; its names start with ef_.
# shellcheck shell=sh
# shellcheck disable=SC2154 # ef_prog is set by each sourcing script

ef_here=$(cd -- "$(dirname -- "$0")/.." && pwd)
ef_writer="${ef_here}/../../crucible-events/scripts/internal/event-write.sh"
ef_reader="${ef_here}/../../crucible-events/scripts/internal/events-read.sh"
ef_efforts="${CRUCIBLE_HOME:-${HOME}/.crucible}/efforts"

ef_refuse() {
	printf '%s: %s\n' "${ef_prog}" "$1" >&2
	exit 2
}

# Refuses unless $1 is an effort folder: absolute, directly in the efforts
# folder, and holding events.
ef_check() {
	case $1 in "${ef_efforts}"/*) ;; *) ef_refuse "$1 is not in ${ef_efforts}" ;; esac
	case ${1#"${ef_efforts}"/} in '' | */*) ef_refuse "$1 is not an effort folder" ;; esac
	[ -d "$1/events" ] && [ ! -L "$1" ] || ef_refuse "$1 is not an effort folder"
}

# Prints effort $1 as one JSON object {folder, name, state, outcome, words,
# at}: state is open, paused or closed; at is the newest effort event's time;
# outcome and words come from that event when it is a pause or a close.
# Exits 2 when the events can't be read; call it in $( ) and pass that on.
ef_summary() {
	ef_events=$(sh "${ef_reader}" --effort "$1" --type 'effort.*') || exit 2
	printf '%s\n' "${ef_events}" \
		| jq --arg folder "$1" '
			last as $now
			| {folder: $folder, name: (first.body.name),
			   state: ({"effort.paused": "paused", "effort.closed": "closed"}[$now.type] // "open"),
			   outcome: $now.body.outcome, words: $now.body.words, left_open: $now.body.left_open, at: $now.at}'
}

# Writes event $1 to effort $2 with body file $3; prints the event's path.
ef_write() {
	sh "${ef_writer}" --effort "$2" --type "$1" --by "${ef_prog}" --body-file "$3"
}
