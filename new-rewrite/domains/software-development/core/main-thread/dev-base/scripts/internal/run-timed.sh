#!/usr/bin/env sh
# Runs a command under a time limit; at the limit, stops it and every process
# it started.
# shellcheck disable=SC2310,SC2312 # any_alive is in a condition for its status; a read inside a message only shortens the message
set -eu

usage() {
	cat <<'USAGE'
usage: sh run-timed.sh --seconds N -- COMMAND [ARG]...

Run by the domain's scripts; not for main to call.
Runs COMMAND with stdin closed. At the limit, COMMAND and every process
beneath it get TERM, then KILL 2 s later if still running.

Options:
  --seconds N  the limit, whole seconds, 1 to 3600
Stdout:    COMMAND's own; the runner adds nothing but a refusal's reason
Exit:
  2    refused, nothing ran; the reason is on stderr
  124  timed out: COMMAND and every process beneath it were stopped
  any other: COMMAND's own exit, COMMAND having ended within the limit
USAGE
}

readonly PROG='run-timed.sh'
readonly MAX_SECONDS=3600
# How long a stopped process may take to end on TERM before it gets KILL.
readonly GRACE_SECONDS=2
readonly TIMED_OUT=124

refuse() {
	printf '%s: %s\n' "${PROG}" "$1" >&2
	exit 2
}

# Prints $1 with each control character as "?", so a value can't split a line.
printable() {
	printf '%s' "$1" | tr '[:cntrl:]' '?'
}

# Stops process $1 and every process beneath it, each by its PID, and prints
# their PIDs: all are frozen first, parents before children, so none can
# start another or leave the tree while it is walked; then each gets TERM and
# is let go.
stop_tree() {
	tree_pids=$(freeze "$1")
	signal_each TERM "${tree_pids}"
	signal_each CONT "${tree_pids}"
	printf '%s\n' "${tree_pids}"
}

# Freezes process $1 and, through pgrep, every process beneath it; prints
# each PID frozen, parents first. Without pgrep only $1 is found.
freeze() {
	kill -STOP "$1" 2>/dev/null || return 0
	printf '%s\n' "$1"
	command -v pgrep >/dev/null 2>&1 || return 0
	pgrep -P "$1" 2>/dev/null | while IFS= read -r child; do
		freeze "${child}"
	done
}

# Sends signal $1 to each PID in the lines of $2.
signal_each() {
	printf '%s\n' "$2" | while IFS= read -r pid; do
		[ -z "${pid}" ] || kill -"$1" "${pid}" 2>/dev/null || :
	done
}

# Succeeds when a PID in the lines of $1 is still running.
any_alive() {
	alive=$(printf '%s\n' "$1" | while IFS= read -r pid; do
		if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then printf 'x'; fi
	done)
	[ -n "${alive}" ]
}

# Waits the limit, then stops process $1's tree, gives it the grace to end,
# kills what is left and exits TIMED_OUT. A TERM before the limit ends the
# watch with exit 0; once the limit has passed, the watch finishes.
watch() {
	fired=no sleep_pid=''
	trap 'if [ "${fired}" = no ]; then [ -z "${sleep_pid}" ] || kill "${sleep_pid}" 2>/dev/null; exit 0; fi' TERM
	sleep "${seconds}" &
	sleep_pid=$!
	wait "${sleep_pid}" || :
	fired=yes
	watched_pids=$(stop_tree "$1")
	waited=0
	while [ "${waited}" -lt "${GRACE_SECONDS}" ] && any_alive "${watched_pids}"; do
		sleep 1
		waited=$((waited + 1))
	done
	! any_alive "${watched_pids}" || signal_each KILL "${watched_pids}"
	exit "${TIMED_OUT}"
}

# Stops the watch and the command's tree, then exits $1: the runner itself
# was told to stop.
# shellcheck disable=SC2329 # run by the traps below
on_signal() {
	[ -z "${watcher_pid}" ] || kill "${watcher_pid}" 2>/dev/null || :
	[ -z "${command_pid}" ] || stop_tree "${command_pid}" >/dev/null
	exit "$1"
}

seconds=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--seconds)
			[ $# -ge 2 ] || refuse '--seconds needs a value'
			seconds=$2
			shift 2 ;;
		--) shift; break ;;
		*) refuse "unknown argument $(printable "$1"); try --help" ;;
	esac
done
[ -n "${seconds}" ] || refuse '--seconds missing'
# A whole number with no leading zero, so the shell never reads it as octal.
case ${seconds} in
	0* | *[!0-9]* | ?????*) refuse "--seconds $(printable "${seconds}") must be a whole number from 1 to ${MAX_SECONDS}" ;;
	*) [ "${seconds}" -le "${MAX_SECONDS}" ] || refuse "--seconds ${seconds} is over ${MAX_SECONDS}" ;;
esac
[ $# -ge 1 ] || refuse 'no COMMAND after --'

command_pid='' watcher_pid=''
trap 'on_signal 129' HUP
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
"$@" </dev/null &
command_pid=$!
watch "${command_pid}" </dev/null >/dev/null 2>&1 &
watcher_pid=$!
rc=0
wait "${command_pid}" 2>/dev/null || rc=$?
command_pid=''
kill "${watcher_pid}" 2>/dev/null || :
watched=0
wait "${watcher_pid}" 2>/dev/null || watched=$?
watcher_pid=''
[ "${watched}" -ne "${TIMED_OUT}" ] || [ "${rc}" -eq 0 ] || exit "${TIMED_OUT}"
exit "${rc}"
