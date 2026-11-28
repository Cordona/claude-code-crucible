# A folder lock, shared by the scripts that write an effort's files: one
# writer at a time. It never refuses and never sets a trap: the caller words
# its own refusal and releases the lock in its own EXIT trap.
# Sourced, so it sets no shell option; its names start with lk_.
# shellcheck shell=sh

# Takes lock folder $1, which holds its owner's pid; a dead owner's lock is
# broken. Returns 1 when the lock stays held for about 5 seconds.
lk_take() {
	lk_tries=0
	until mkdir -- "$1" 2>/dev/null; do
		lk_holder=$(cat -- "$1/pid" 2>/dev/null || true)
		if [ -n "${lk_holder}" ] && ! kill -0 "${lk_holder}" 2>/dev/null; then
			rm -rf -- "$1"
			continue
		fi
		lk_tries=$((lk_tries + 1))
		[ "${lk_tries}" -lt 50 ] || return 1
		sleep 0.1
	done
	printf '%s\n' "$$" >"$1/pid"
}

# Releases lock folder $1.
lk_release() {
	rm -rf -- "$1"
}
