# The owed-card store, shared by show-card.sh and the gate hooks: where a
# session's records live, which ids are safe, how long a record lives, how
# and how often a missing card is sent back.
# Records are throwaway cache, edited and removed freely; they are never
# events. Sourced, so it sets no shell option; its names start with og_.
# shellcheck shell=sh
# shellcheck disable=SC2034 # og_ values are read by the sourcing scripts

# 30 minutes: long enough to read a card, short enough that a record left by
# an abandoned turn soon stops holding a question.
og_stale_seconds=1800
# 2 tries: a copy slip is fixed in one or two; after that the stop goes
# through instead of looping.
og_max_tries=2

# Succeeds when $1 is safe as one path part: letters, digits, ".", "_", "-".
og_safe_id() {
	case $1 in
		'' | . | .. | *[!A-Za-z0-9._-]*) return 1 ;;
		*) return 0 ;;
	esac
}

# Sets og_dir, the owed folder of session $1.
og_set_dir() {
	og_dir="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/cache/crucible-gate/$1/owed"
}

# Prints the session's live record files, one per line, removing stale ones.
og_records() {
	[ -d "${og_dir}" ] || return 0
	og_now=$(date +%s)
	for og_file in "${og_dir}"/*.json; do
		[ -f "${og_file}" ] && [ ! -L "${og_file}" ] || continue
		og_at=$(jq -r '.at // 0' "${og_file}" 2>/dev/null) || og_at=0
		if [ $((og_now - og_at)) -gt "${og_stale_seconds}" ]; then
			rm -f -- "${og_file}"
		else
			printf '%s\n' "${og_file}"
		fi
	done
}

