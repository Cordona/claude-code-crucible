# Whether a job's report is pinned: a file, not a link, that its owner can't
# write, as agent-submission's pin makes it (chmod 444). Sourced, so it sets
# no shell option; its names start with pn_.
# shellcheck shell=sh

# Succeeds when report file $1 is pinned.
pn_pinned() {
	[ -f "$1" ] && [ ! -L "$1" ] || return 1
	pn_writable=$(find "$1" -prune -perm -200) || return 1
	[ -z "${pn_writable}" ]
}
