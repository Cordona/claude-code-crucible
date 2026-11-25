# The stop hook's own lock, one per effort, held from the stamp to the
# event, so two agents stopping at once take turns: their stamps can't both
# take the same ID, and neither event is lost. It is not the events' lock.
# It never refuses and sets no trap: the caller releases it in its own EXIT
# trap. Sourced, so it sets no shell option; its names start with sl_.
# shellcheck shell=sh

# The longest wait, in seconds: long enough for twelve stops queued on one
# effort, short enough that the wait plus the commit stays well inside the
# stop hook's 300-second timeout, so the hook says its own fault before
# Claude Code ends it. CRUCIBLE_STOP_LOCK_SECONDS may only shorten it.
sl_wait_max=120

# Takes lock folder $1, which holds its owner's pid; a dead owner's lock is
# broken. Returns 1 when the lock stays held for the whole wait.
sl_take() {
	sl_wait=${CRUCIBLE_STOP_LOCK_SECONDS:-${sl_wait_max}}
	case ${sl_wait} in '' | *[!0-9]*) sl_wait=${sl_wait_max} ;; *) ;; esac
	[ "${sl_wait}" -le "${sl_wait_max}" ] || sl_wait=${sl_wait_max}
	sl_deadline=$(($(date +%s) + sl_wait))
	until mkdir -- "$1" 2>/dev/null; do
		sl_holder=$(cat -- "$1/pid" 2>/dev/null || true)
		if [ -n "${sl_holder}" ] && ! kill -0 "${sl_holder}" 2>/dev/null; then
			rm -rf -- "${1:?}"
			continue
		fi
		sl_now=$(date +%s) || return 1
		[ "${sl_now}" -lt "${sl_deadline}" ] || return 1
		sleep 0.1
	done
	printf '%s\n' "$$" >"$1/pid"
}

# Releases lock folder $1.
sl_release() {
	rm -rf -- "${1:?}"
}
