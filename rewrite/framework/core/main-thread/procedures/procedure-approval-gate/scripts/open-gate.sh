#!/usr/bin/env sh
# Opens an approval gate: appends the gate marker to the rendered plan on
# stdin, stores the result as this session's gate, and prints exactly the
# stored text, which the main thread relays word for word as its last message.
# gate-stop-hook.sh and gate-question-hook.sh read the same state.
# shellcheck source-path=SCRIPTDIR
set -eu

readonly PROG='open-gate.sh'
readonly MARKER='_Crucible gate_'
readonly REQUIRED_TOOLS='awk cat chmod cmp date find mkdir mktemp mv rm touch'
# Same bound as both hooks: a gate older than this is treated as absent.
readonly STALE_SECONDS=1800
readonly STALE_MINUTES=$((STALE_SECONDS / 60))
readonly SPACE_LIB_TEXT="\${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/skills/crucible/scripts/lib/crucible-space.sh"
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
usage: sh ${PROG} --plan-path
       <renderer> --plan-file PATH | sh ${PROG} --label LABEL [--effort FOLDER]
       <renderer> --plan-file PATH | sh ${PROG} --show-only
       sh ${PROG} --help | -h

Opens this session's approval gate for the rendered plan on stdin and prints
the gate text to relay.

Options:
  --plan-path       print the session's plan file path; opens no gate; takes
                    no other option
  --label LABEL     open a pending gate, its record saved under LABEL, the
                    label the gate's procedure sets (such as dispatch-plan), a
                    Crucible item label (see crucible.sh --help); needed
                    unless --plan-path or --show-only
  --effort FOLDER   the absolute effort folder the gate belongs to, as
                    effort.sh start printed, under
                    \${CRUCIBLE_HOME:-\$HOME/.crucible}/efforts/: the record
                    is saved in its cache/gates/; without --effort, in the
                    session's gate folder, never in the Crucible space
  --show-only       open a gate that shows the plan and asks nothing; saves no
                    record, so takes no --label or --effort

Environment:
  CLAUDE_CODE_SESSION_ID  the session id Claude Code sets in the Bash tool

stdout with --plan-path: one absolute path, the session's plan file
stdout otherwise: the gate text, its last line ${MARKER}, word for word

Writes, under \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/cache/approval-gate/ only:
  the session's gate folder, owner-only; a gate replaces the session's earlier
    gate and leaves its plan file in place; --plan-path writes no file
  a pending gate's target file, read by gate-question-hook.sh: the lines
    "label <LABEL>" and "effort <FOLDER, or empty>"
  other sessions' gate folders idle for ${STALE_MINUTES} minutes (no gate opened, nothing
    changed) are removed; a symbolic link is never followed or removed
Nothing else is left behind (a SIGKILL aside). Exit 2 or 5 leaves
everything as it was.

Exit codes:
  0  done; relay the gate text, or (--plan-path) write the plan at the path
  1  the plan or the gate folder could not be processed; show the human
     stderr and the exit code
  2  refused input; fix what stderr names and rerun once, else show the
     human stderr
  5  install fault; show the human stderr, which names what to install
  129, 130, 143  stopped by HUP, INT or TERM; show the human the exit code

Dependencies (a missing one exits 5, named):
  POSIX sh; ${REQUIRED_TOOLS}
    (every macOS and Linux base system; find with -mmin)
  with --label: the crucible skill's space rules,
    ${SPACE_LIB_TEXT}
    (install the crucible skill)
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
	[ -z "${target_temp}" ] || rm -f "${target_temp}"
}

# Exits 2 unless $1 is a session id safe to use as one folder name.
check_session_id() {
	case $1 in
		'') die 2 'CLAUDE_CODE_SESSION_ID missing; expected Claude Code to set it in the Bash tool; try running this from the Bash tool' ;;
		. | .. | *[!A-Za-z0-9._-]*) die 2 'CLAUDE_CODE_SESSION_ID holds characters a folder name cannot safely carry; expected only letters, digits, ".", "_" and "-"; try running this from the Bash tool, which sets it' ;;
		*) ;;
	esac
}

# Sets gate_root (absolute), gate_dir and plan_path, and refuses a symbolic link at
# either, or (--plan-path) at plan.json. Runs before anything is touched: a
# linked root would put this session's gate outside it.
check_gate_paths() {
	gate_root="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/cache/approval-gate"
	case ${gate_root} in
		/*) ;;
		*) gate_root="$(pwd)/${gate_root}" ;;
	esac
	gate_dir="${gate_root}/$1"
	plan_path="${gate_dir}/plan.json"
	[ ! -L "${gate_root}" ] || die 1 "${gate_root} is a symbolic link; expected a plain folder; try removing the link, then rerun"
	[ ! -L "${gate_dir}" ] || die 1 "state folder is a symbolic link: ${gate_dir}; expected a plain folder; try removing the link, then rerun"
	[ "${action}" != plan-path ] || [ ! -L "${plan_path}" ] ||
		die 1 "plan file is a symbolic link: ${plan_path}; expected a plain file or none; try removing the link, then rerun"
}

# Creates the session's state folder with mode 700 and marks it in use (its
# modification time is now, which keeps other sessions' sweeps off it while
# the plan is written), at the gate_dir check_gate_paths set.
make_gate_dir() {
	mkdir -p "${gate_dir}" || die 1 "cannot create the state folder ${gate_dir}; expected a writable \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/cache; try checking its owner and free space, then rerun"
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
		pending | relayed | shown | failed) ;;
		*) return 1 ;;
	esac
	case ${state_tries}:${state_opened} in
		:* | *: | *[!0-9:]* | *:*:* | 0?*:* | *:0?*) return 1 ;;
		*) ;;
	esac
}

# True when gate folder $1 may be in use: its gate opened within STALE_SECONDS,
# or the folder or anything in it changed within that time, or find cannot
# tell. A stale gate state does not make a folder stale: a session writes its
# next plan.json beside its last gate's state before it opens the next gate.
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

# Stores the marked text $1 as gate.md, the target file and state line
# "$2 <tries> now", then prints gate.md.
store_gate() {
	write_fix="expected a writable ${gate_dir}; try checking its owner and free space, then rerun"
	gate_temp=$(mktemp "${gate_dir}/gate.md.XXXXXX") || die 1 "cannot create a temp file in ${gate_dir}; ${write_fix}"
	printf '%s\n' "$1" >"${gate_temp}" || die 1 "cannot write ${gate_temp}; ${write_fix}"
	tries=0
	if [ "$2" = pending ]; then tries=$(carried_tries); fi
	state_temp=$(mktemp "${gate_dir}/state.XXXXXX") || die 1 "cannot create a temp file in ${gate_dir}; ${write_fix}"
	printf '%s %s %s\n' "$2" "${tries}" "${now}" >"${state_temp}" || die 1 "cannot write ${state_temp}; ${write_fix}"
	# gate.md and the target land before state, so a hook never sees a new
	# state with an old plan or an old target.
	mv -f "${gate_temp}" "${gate_dir}/gate.md" || die 1 "cannot write ${gate_dir}/gate.md; ${write_fix}"
	gate_temp=''
	store_target
	mv -f "${state_temp}" "${gate_dir}/state" || die 1 "cannot write ${gate_dir}/state; ${write_fix}"
	state_temp=''
	cat "${gate_dir}/gate.md"
}

# Writes the target file (label, then effort) for a pending gate, or removes
# an earlier one for a shown gate, which saves no record.
store_target() {
	if [ "${gate_state}" = shown ]; then
		rm -f "${gate_dir}/target" || die 1 "cannot remove ${gate_dir}/target; ${write_fix}"
		return 0
	fi
	target_temp=$(mktemp "${gate_dir}/target.XXXXXX") || die 1 "cannot create a temp file in ${gate_dir}; ${write_fix}"
	printf 'label %s\neffort %s\n' "${label}" "${effort}" >"${target_temp}" || die 1 "cannot write ${target_temp}; ${write_fix}"
	mv -f "${target_temp}" "${gate_dir}/target" || die 1 "cannot write ${gate_dir}/target; ${write_fix}"
	target_temp=''
}

# Sets action, gate_state, label and effort from the arguments, or exits 2.
parse_args() {
	action=open gate_state=pending label='' effort='' seen=''
	while [ "$#" -gt 0 ]; do
		case $1 in
			--help | -h)
				usage
				exit 0
				;;
			--show-only | --plan-path | --label | --effort) ;;
			*) usage_error "unknown argument: $1; expected --plan-path, --label, --effort, --show-only or --help" ;;
		esac
		case "${seen} " in
			*" $1 "*) usage_error "$1 given twice; expected it at most once" ;;
			*) seen="${seen} $1" ;;
		esac
		case $1 in
			--show-only) gate_state=shown ;;
			--plan-path) action=plan-path ;;
			*)
				[ "$#" -ge 2 ] || usage_error "$1 needs a value; expected $1 VALUE"
				if [ "$1" = --label ]; then label=$2; else effort=$2; fi
				shift
				;;
		esac
		shift
	done
	check_combination
}

# Exits 2 unless the arguments go together: --plan-path alone, --show-only
# without a record's options, and a pending gate with its --label.
check_combination() {
	if [ "${action}" = plan-path ]; then
		[ "${seen}" = ' --plan-path' ] || usage_error '--plan-path takes no other argument; expected --plan-path alone'
		return 0
	fi
	if [ "${gate_state}" = shown ]; then
		[ "${seen}" = ' --show-only' ] || usage_error '--show-only saves no record; expected it without --label or --effort'
		return 0
	fi
	[ -n "${label}" ] || usage_error "--label missing or empty; expected --label LABEL, the plan's kind, such as dispatch-plan"
	load_space_lib
	check_label
	case "${seen} " in
		*" --effort "*) check_effort ;;
		*) ;;
	esac
}

# Sources the crucible skill's space rules, or exits 5.
load_space_lib() {
	space_lib="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/skills/crucible/scripts/lib/crucible-space.sh"
	[ -f "${space_lib}" ] && [ -r "${space_lib}" ] ||
		die 5 "space rules missing; expected ${space_lib}; try installing the crucible skill"
	# shellcheck source=../../../../engine/crucible/scripts/lib/crucible-space.sh
	. "${space_lib}"
}

check_label() {
	# shellcheck disable=SC2310 # a pure test; its status is the answer
	crucible_is_label "${label}" || usage_error "${crucible_label_refusal}"
}

# Exits 2 unless effort names a real effort folder of the Crucible space, by
# the space rules. The target file is line-based, so a control character is
# refused before the path is shown.
check_effort() {
	[ -n "${effort}" ] || usage_error '--effort is empty; expected --effort FOLDER, the effort folder effort.sh start printed'
	case ${effort} in
		*[[:cntrl:]]*) usage_error '--effort holds a control character; expected the effort folder effort.sh start printed' ;;
		*) ;;
	esac
	# shellcheck disable=SC2310 # its status says whether the root is usable; the problem is read below
	crucible_resolve_root || usage_error "--effort needs the Crucible space: ${crucible_root_problem}"
	# shellcheck disable=SC2310 # its status says whether the folder passed; the problem is read below
	crucible_check_effort_folder "${effort}" || usage_error "${crucible_effort_refusal}"
	effort=${crucible_effort}
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
target_temp=''
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
		3) usage_error 'empty input; expected the rendered gate plan on stdin; if a renderer was piped in, it printed nothing: check its stderr above; otherwise try piping the renderer into this script' ;;
		*) die 1 "awk failed (exit ${mark_status}) reading the plan; expected a POSIX awk; try checking awk on PATH, then rerun" ;;
	esac
fi
now=$(date +%s) || die 1 'date +%s failed; expected a date that supports %s; try a POSIX date on PATH'

check_gate_paths "${session_id}"
make_gate_dir
sweep_other_gates
if [ "${action}" = plan-path ]; then
	printf '%s\n' "${plan_path}"
else
	store_gate "${gate_text}" "${gate_state}"
fi
