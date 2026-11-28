# The door's notes, shared by job-assign.sh and its hooks: where a
# session's notes live. Notes are throwaway
# cache, never events. Sourced, so it sets no shell option; its names start
# with nt_.
# shellcheck shell=sh

# Sets nt_dir, the notes folder of session $1; fails for an unsafe id.
nt_set_dir() {
	case $1 in '' | . | .. | *[!A-Za-z0-9._-]*) return 1 ;; *) ;; esac
	nt_dir="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/cache/jobs-assign/$1"
}
