#!/usr/bin/env sh
# Opens this session's gate: appends the gate marker to the rendered view on
# stdin, stores the result as the session's pending gate, and prints exactly
# the stored text, which the main thread relays word for word as the turn's
# last message. gate-stop-hook.sh and gate-question-hook.sh read the same
# state.
set -eu

readonly PROG='open-gate.sh'
readonly MARKER='_Harness gate_'
readonly REQUIRED_TOOLS='awk cat chmod cmp date find mkdir mktemp mv rm touch'
# Same bound as both hooks: a gate older than this is treated as absent.
readonly STALE_SECONDS=1800
readonly STALE_MINUTES=$((STALE_SECONDS / 60))
# The C locale makes awk byte-wise and identical on every platform.
LC_ALL=C
export LC_ALL

# Drops trailing blank (whitespace-only) lines and appends "\n<marker>\n";
# exit 3 when every line is blank.
# The program is single-quoted on purpose: its $ signs are awk's.
# shellcheck disable=SC2016
readonly MARK_AWK='
/^[[:space:]]*$/ { held = held $0 "\n"; next }
{ printf "%s%s\n", held, $0; held = ""; has_text = 1 }
END {
	if (!has_text) exit 3
	printf "\n%s\n", marker
}
'

usage() {
	cat <<EOF
usage: <renderer> | sh ${PROG}
       sh ${PROG} --help | -h

Opens this session's gate for the rendered view on stdin and prints the gate
text to relay. Takes no option but --help.

stdin: the rendered view (render-gate.sh's stdout); trailing blank lines are
  dropped

Environment:
  CLAUDE_CODE_SESSION_ID  the session id Claude Code sets in the Bash tool

stdout: the gate text, word for word: the view, a blank line, and the last
  line ${MARKER}

Writes, under \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/cache/harness-gate/ only:
  the session's gate folder <session_id>/, owner-only (mode 700), holding
    gate.md (the gate text) and state (one line: pending <tries> <opened>);
    each lands whole, by rename; a gate replaces the session's earlier one,
    and reopening the same text while it is pending keeps its relay tries
  other sessions' gate folders idle for ${STALE_MINUTES} minutes (no gate opened, nothing
    changed) are removed; a symbolic link is never followed or removed
Nothing else is left behind (a SIGKILL aside). Exit 2 or 5 writes nothing.

Exit codes:
  0  done; relay the gate text as the turn's last message
  1  the gate folder could not be written; show the human stderr and the exit
     code
  2  refused input (empty stdin, an unknown argument, a missing or unsafe
     CLAUDE_CODE_SESSION_ID); fix what stderr names and rerun once, else
     show the human stderr
  5  install fault; show the human stderr, which names what to install
  129, 130, 143  stopped by HUP, INT or TERM; show the human the exit code

Dependencies (a missing one exits 5, named):
  POSIX sh; ${REQUIRED_TOOLS}
    (every macOS and Linux base system; find with -mmin)
EOF
}

warn() {
	printf '%s: %s\n' "${PROG}" "$1" >&2
}

die() {
	warn "$2"
	exit "$1"
}

usage_error() {
	warn "$1"
	printf "Try '%s --help'.\n" "${PROG}" >&2
	exit 2
}

# shellcheck disable=SC2329 # invoked by the EXIT trap
remove_temp_files() {
	[ -z "${gate_temp}" ] || rm -f "${gate_temp}"
	[ -z "${state_temp}" ] || rm -f "${state_temp}"
}

parse_args() {
	case $# in
		0) return 0 ;;
		*) ;;
	esac
	case $1 in
		--help | -h)
			usage
			exit 0
			;;
		*) usage_error "unknown argument: $1; expected no argument, or --help" ;;
	esac
}

# Exits 2 unless $1 is a session id safe to use as one folder name.
check_session_id() {
	case $1 in
		'') die 2 'CLAUDE_CODE_SESSION_ID missing; expected Claude Code to set it in the Bash tool; try running this from the Bash tool' ;;
		. | .. | *[!A-Za-z0-9._-]*) die 2 'CLAUDE_CODE_SESSION_ID holds characters a folder name cannot safely carry; expected only letters, digits, ".", "_" and "-"; try running this from the Bash tool, which sets it' ;;
		*) ;;
	esac
}

# Sets gate_root (absolute) and gate_dir, and refuses a symbolic link at
# either before anything is touched: a linked root would put the gate
# outside it.
check_gate_paths() {
	gate_root="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/cache/harness-gate"
	case ${gate_root} in
		/*) ;;
		*) gate_root="$(pwd)/${gate_root}" ;;
	esac
	gate_dir="${gate_root}/$1"
	[ ! -L "${gate_root}" ] || die 1 "${gate_root} is a symbolic link; expected a plain folder; try removing the link, then rerun"
	[ ! -L "${gate_dir}" ] || die 1 "gate folder is a symbolic link: ${gate_dir}; expected a plain folder; try removing the link, then rerun"
}

# Creates the session's gate folder with mode 700 and marks it in use (its
# modification time is now, which keeps other sessions' sweeps off it).
make_gate_dir() {
	mkdir -p "${gate_dir}" || die 1 "cannot create the gate folder ${gate_dir}; expected a writable \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/cache; try checking its owner and free space, then rerun"
	chmod 700 "${gate_dir}" || die 1 "cannot set mode 700 on ${gate_dir}; expected a folder your user owns; try checking its owner, then rerun"
	touch "${gate_dir}" || die 1 "cannot set the modification time of ${gate_dir}; expected a folder your user owns; try checking its owner, then rerun"
}

# Sets state_status, state_tries and state_opened from the state file $1.
# False when it is missing, a symbolic link, or not a well-formed state line
# (digits only, no leading zero, which sh arithmetic would read as octal).
read_state() {
	[ -f "$1" ] && [ ! -L "$1" ] || return 1
	state_status=''
	state_tries=''
	state_opened=''
	read -r state_status state_tries state_opened _ <"$1" || true
	case ${state_status} in
		pending | relayed | failed) ;;
		*) return 1 ;;
	esac
	case ${state_tries}:${state_opened} in
		:* | *: | *[!0-9:]* | *:*:* | 0?*:* | *:0?*) return 1 ;;
		*) ;;
	esac
}

# True when gate folder $1 may be in use: its gate opened within
# STALE_SECONDS, or anything in it (the folder included) changed within that
# time, or find cannot tell.
is_live_gate_dir() {
	# shellcheck disable=SC2310 # its status is the answer; set -e is not needed inside
	if read_state "$1/state" && [ $((now - state_opened)) -le "${STALE_SECONDS}" ]; then
		return 0
	fi
	recent=$(find "$1" ! -mmin "+${STALE_MINUTES}" 2>/dev/null) || return 0
	[ -n "${recent}" ]
}

# Removes other sessions' stale gate folders in gate_root, which
# check_gate_paths has checked is no link. Plain folders only: a linked entry
# is never followed or removed.
sweep_other_gates() {
	for entry in "${gate_root}"/*; do
		[ ! -L "${entry}" ] && [ -d "${entry}" ] || continue
		[ "${entry##*/}" != "${session_id}" ] || continue
		# shellcheck disable=SC2310 # its status is the answer; set -e is not needed inside
		if ! is_live_gate_dir "${entry}"; then
			rm -rf "${entry}" ||
				warn "cannot remove the stale gate folder ${entry}; expected a folder your user owns; left in place; check its owner"
		fi
	done
}

# Prints the tries to carry over: the pending gate's count when gate_temp
# holds the same text as its gate.md and it is not stale, otherwise 0.
carried_tries() {
	# shellcheck disable=SC2310 # its status is the answer; set -e is not needed inside
	if read_state "${gate_dir}/state" && [ "${state_status}" = pending ] &&
		[ $((now - state_opened)) -le "${STALE_SECONDS}" ] &&
		[ ! -L "${gate_dir}/gate.md" ] && cmp -s "${gate_temp}" "${gate_dir}/gate.md"; then
		echo "${state_tries}"
	else
		echo 0
	fi
}

# Stores the marked text $1 as gate.md and the state line
# "pending <tries> <now>", then prints gate.md.
store_gate() {
	write_fix="expected a writable ${gate_dir}; try checking its owner and free space, then rerun"
	gate_temp=$(mktemp "${gate_dir}/gate.md.XXXXXX") || die 1 "cannot create a temp file in ${gate_dir}; ${write_fix}"
	printf '%s\n' "$1" >"${gate_temp}" || die 1 "cannot write ${gate_temp}; ${write_fix}"
	tries=$(carried_tries)
	state_temp=$(mktemp "${gate_dir}/state.XXXXXX") || die 1 "cannot create a temp file in ${gate_dir}; ${write_fix}"
	printf 'pending %s %s\n' "${tries}" "${now}" >"${state_temp}" || die 1 "cannot write ${state_temp}; ${write_fix}"
	# gate.md lands before state, so a hook never sees a new state with an
	# old gate text.
	mv -f "${gate_temp}" "${gate_dir}/gate.md" || die 1 "cannot write ${gate_dir}/gate.md; ${write_fix}"
	gate_temp=''
	mv -f "${state_temp}" "${gate_dir}/state" || die 1 "cannot write ${gate_dir}/state; ${write_fix}"
	state_temp=''
	cat "${gate_dir}/gate.md"
}

parse_args "$@"

for tool in ${REQUIRED_TOOLS}; do
	command -v "${tool}" >/dev/null 2>&1 ||
		die 5 "${tool} missing; expected it on PATH; try installing your base system's ${tool}"
done

session_id="${CLAUDE_CODE_SESSION_ID-}"
check_session_id "${session_id}"
umask 077
gate_temp=''
state_temp=''
trap remove_temp_files EXIT
# A signal exits through the EXIT trap, so the temp files go on every path.
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# The text is built before the folder exists, so bad input writes nothing.
# $(...) drops the final newline; store_gate's printf restores it.
if gate_text=$(awk -v marker="${MARKER}" "${MARK_AWK}"); then
	mark_status=0
else
	mark_status=$?
fi
case ${mark_status} in
	0) ;;
	3) usage_error 'empty input; expected the rendered gate view on stdin; if a renderer was piped in, it printed nothing: check its stderr above; otherwise try piping the renderer into this script' ;;
	*) die 1 "awk failed (exit ${mark_status}) reading the view; expected a POSIX awk; try checking awk on PATH, then rerun" ;;
esac
now=$(date +%s) || die 1 'date +%s failed; expected a date that supports %s; try a POSIX date on PATH'

check_gate_paths "${session_id}"
make_gate_dir
sweep_other_gates
store_gate "${gate_text}"
