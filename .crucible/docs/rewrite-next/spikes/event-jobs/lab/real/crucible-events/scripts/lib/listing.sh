# The one listing of an effort's event files, and the one rule for a type's
# name, used by event-write.sh and events-read.sh: the only place that knows
# either.
# Sourced, so it sets no shell option; its names start with ls_.
# shellcheck shell=sh

# Prints the event files of effort folder $1, absolute, in seq order, one per
# line; with $2, only type $2 (a trailing .* takes a family, as effort.*).
# Prints nothing when there are none.
ls_events() {
	[ -d "$1/events" ] || return 0
	find "$1/events" -maxdepth 1 -type f -name "[0-9]*-${2:-*}.json" | LC_ALL=C sort
}

# A type's name: lowercase words (letters and hyphens) joined by dots, at
# least two words, as effort.closed.
ls_word='[a-z][a-z-]*'

# Returns 0 when $1 is a type's name.
ls_is_type() {
	printf '%s\n' "$1" | grep -Eqx "${ls_word}(\.${ls_word})+"
}

# Returns 0 when $1 is a family of types: the first words of a type, then .*,
# as effort.*.
ls_is_family() {
	printf '%s\n' "$1" | grep -Eqx "${ls_word}(\.${ls_word})*\.\*"
}
