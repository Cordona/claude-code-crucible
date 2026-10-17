#!/usr/bin/env sh
# Opens an approval gate: appends the gate marker to the rendered plan on
# stdin, stores the result as this session's gate, and prints exactly the
# stored text, which the main thread relays word for word as its last message.
# gate-stop-hook.sh and gate-question-hook.sh read the same state.
set -eu

readonly PROG='open-gate.sh'
readonly MARKER='_Crucible gate_'
readonly REQUIRED_TOOLS='awk cat chmod cmp date find mkdir mktemp mv rm'
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
Usage: sh ${PROG} --plan-path
       <renderer> --plan-file <path> | sh ${PROG} [--show-only]
  e.g. sh ${PROG} --plan-path         (prints <path>; write the plan JSON there)
       sh render-dispatch-plan.sh --plan-file <path> | sh ${PROG}

The session's gate folder is
  \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/cache/approval-gate/<session id>/
(mode 700, files 600; a folder that is a symbolic link is refused).
  --plan-path  creates the gate folder and prints the absolute path
               <gate folder>/plan.json, where the caller writes the
               renderer's input. Reads no stdin, writes no file, opens no gate.
               plan.json goes with the gate: a hook removes it when it clears
               the gate or removes a stale or malformed one, and when it is
               older than ${STALE_SECONDS}s with no gate state beside it.
  (default)    reads a rendered gate plan (Markdown) on stdin, drops its
               trailing blank lines, appends "\n${MARKER}\n", and prints
               exactly that text. It stores the text as gate.md, plus a state
               line "<state> <tries> <opened epoch>", replacing any earlier
               gate of this session; plan.json stays. State "pending", 0 tries:
               the Stop hook checks the relay and the question hook denies the
               question until it is relayed. When the text equals the
               session's pending gate.md (opened less than ${STALE_SECONDS}s
               ago), the gate keeps its tries.
  --show-only  as the default, state "shown": a plan shown with no question;
               the Stop hook lets the stop through and the question hook
               clears it.
Every run but --help also removes other sessions' gate folders in
cache/approval-gate/ whose gate opened more than ${STALE_SECONDS}s ago, or that
hold no gate state and are older than that. It never follows a symbolic link
and touches nothing outside cache/approval-gate/.
The session id comes from CLAUDE_CODE_SESSION_ID, which Claude Code sets in the
Bash tool; it must hold only letters, digits, ".", "_" and "-".
Input is checked before anything is written.

Exit codes:
  0              the gate opened and its text is on stdout, or (--plan-path)
                 the plan path is on stdout
  1              the plan could not be processed (awk or date failed), or the
                 gate folder or its state could not be written
  2              usage error: an unknown argument, CLAUDE_CODE_SESSION_ID
                 missing or unsafe, or empty input
  5              a required tool missing from PATH
  129, 130, 143  stopped by HUP, INT or TERM; temp files are removed

Dependencies: POSIX sh, ${REQUIRED_TOOLS}; checked at
start, a missing one exits 5. find needs -mmin, as on macOS and Linux.
Runtime: about 29 ms, measured on macOS (average of 5 runs).
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

# Exits 2 unless $1 is a session id safe to use as one folder name.
check_session_id() {
	case $1 in
		'') die 2 'CLAUDE_CODE_SESSION_ID missing; expected Claude Code to set it in the Bash tool; try running this from the Bash tool' ;;
		. | .. | *[!A-Za-z0-9._-]*) die 2 'CLAUDE_CODE_SESSION_ID holds characters a folder name cannot safely carry; expected only letters, digits, ".", "_" and "-"; try running this from the Bash tool, which sets it' ;;
		*) ;;
	esac
}

# Creates the session's state folder with mode 700; sets gate_root (absolute)
# and gate_dir.
make_gate_dir() {
	gate_root="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/cache/approval-gate"
	case ${gate_root} in
		/*) ;;
		*) gate_root="$(pwd)/${gate_root}" ;;
	esac
	gate_dir="${gate_root}/$1"
	[ ! -L "${gate_dir}" ] || die 1 "state folder is a symbolic link: ${gate_dir}; expected a plain folder; try removing the link, then rerun"
	mkdir -p "${gate_dir}" || die 1 "cannot create the state folder ${gate_dir}; expected a writable \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/cache; try checking its owner and free space, then rerun"
	chmod 700 "${gate_dir}" || die 1 "cannot set mode 700 on ${gate_dir}; expected a folder your user owns; try checking its owner, then rerun"
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
		pending | relayed | shown | failed) ;;
		*) return 1 ;;
	esac
	case ${state_tries}:${state_opened} in
		:* | *: | *[!0-9:]* | *:*:* | 0?*:* | *:0?*) return 1 ;;
		*) ;;
	esac
}

# True when gate folder $1 is stale: its gate opened more than STALE_SECONDS
# ago, or it holds no well-formed state and the folder is older than that.
is_stale_gate_dir() {
	# shellcheck disable=SC2310 # its status is the answer; set -e is not needed inside
	if read_state "$1/state"; then
		[ $((now - state_opened)) -gt "${STALE_SECONDS}" ]
	else
		old_folder=$(find "$1" -prune -type d -mmin "+${STALE_MINUTES}") || return 1
		[ -n "${old_folder}" ]
	fi
}

# Removes other sessions' stale gate folders in gate_root. Plain folders only:
# a symbolic link, at the root or as an entry, is never followed or removed.
sweep_other_gates() {
	[ ! -L "${gate_root}" ] || {
		warn "${gate_root} is a symbolic link; expected a plain folder; stale gates of other sessions left in place; check where the link points"
		return 0
	}
	for entry in "${gate_root}"/*; do
		[ ! -L "${entry}" ] && [ -d "${entry}" ] || continue
		[ "${entry##*/}" != "${session_id}" ] || continue
		# shellcheck disable=SC2310 # its status is the answer; set -e is not needed inside
		if is_stale_gate_dir "${entry}"; then
			rm -rf "${entry}" ||
				warn "cannot remove the stale gate folder ${entry}; expected a folder your user owns; left in place; check its owner"
		fi
	done
}

# Prints the tries to carry over: the pending gate's count when gate_temp holds
# the same text as its gate.md and it is not stale, otherwise 0.
carried_tries() {
	# shellcheck disable=SC2310 # its status is the answer; set -e is not needed inside
	if read_state "${gate_dir}/state" && [ "${state_status}" = pending ] &&
		[ $((now - state_opened)) -le "${STALE_SECONDS}" ] &&
		cmp -s "${gate_temp}" "${gate_dir}/gate.md"; then
		echo "${state_tries}"
	else
		echo 0
	fi
}

# Prints the absolute path of the session's plan file, refusing a link there.
print_plan_path() {
	plan_path="${gate_dir}/plan.json"
	[ ! -L "${plan_path}" ] || die 1 "plan file is a symbolic link: ${plan_path}; expected a plain file or none; try removing the link, then rerun"
	printf '%s\n' "${plan_path}"
}

# Stores the marked text $1 as gate.md and state line "$2 <tries> now", then
# prints gate.md.
store_gate() {
	write_fix="expected a writable ${gate_dir}; try checking its owner and free space, then rerun"
	gate_temp=$(mktemp "${gate_dir}/gate.md.XXXXXX") || die 1 "cannot create a temp file in ${gate_dir}; ${write_fix}"
	printf '%s\n' "$1" >"${gate_temp}" || die 1 "cannot write ${gate_temp}; ${write_fix}"
	tries=0
	if [ "$2" = pending ]; then tries=$(carried_tries); fi
	state_temp=$(mktemp "${gate_dir}/state.XXXXXX") || die 1 "cannot create a temp file in ${gate_dir}; ${write_fix}"
	printf '%s %s %s\n' "$2" "${tries}" "${now}" >"${state_temp}" || die 1 "cannot write ${state_temp}; ${write_fix}"
	# gate.md lands before state, so a hook never sees a new state with an old plan.
	mv -f "${gate_temp}" "${gate_dir}/gate.md" || die 1 "cannot write ${gate_dir}/gate.md; ${write_fix}"
	gate_temp=''
	mv -f "${state_temp}" "${gate_dir}/state" || die 1 "cannot write ${gate_dir}/state; ${write_fix}"
	state_temp=''
	cat "${gate_dir}/gate.md"
}

action=open
gate_state=pending
case ${1-} in
	--help | -h)
		usage
		exit 0
		;;
	--show-only) gate_state=shown ;;
	--plan-path) action=plan-path ;;
	'') ;;
	*) usage_error "unknown argument: $1; expected no arguments, --plan-path, --show-only or --help" ;;
esac
[ "$#" -le 1 ] || usage_error "unexpected extra argument: $2; expected at most one argument"

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

if [ "${action}" = open ]; then
	# The text is built before the folder exists, so bad input writes nothing.
	# $(...) drops the final newline; store_gate's printf restores it.
	if gate_text=$(awk -v marker="${MARKER}" "${MARK_AWK}"); then
		mark_status=0
	else
		mark_status=$?
	fi
	case ${mark_status} in
		0) ;;
		3) usage_error 'empty input; expected the rendered gate plan on stdin; try piping the renderer into this script' ;;
		*) die 1 "awk failed (exit ${mark_status}) reading the plan; expected a POSIX awk; try checking awk on PATH, then rerun" ;;
	esac
fi
now=$(date +%s) || die 1 'date +%s failed; expected a date that supports %s; try a POSIX date on PATH'

make_gate_dir "${session_id}"
sweep_other_gates
if [ "${action}" = plan-path ]; then
	print_plan_path
else
	store_gate "${gate_text}" "${gate_state}"
fi
