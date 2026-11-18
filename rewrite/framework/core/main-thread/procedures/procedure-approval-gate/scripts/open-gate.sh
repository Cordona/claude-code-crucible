#!/usr/bin/env sh
# Opens an approval gate: renders the plan on stdin as the gate card, through
# human-view's show.sh, which prints it and records it as owed this session;
# show-stop-hook.sh and gate-question-hook.sh read that record.
# shellcheck source-path=SCRIPTDIR
set -eu

readonly PROG='open-gate.sh'
readonly REQUIRED_TOOLS='chmod find jq mkdir rm touch'
readonly HV_SCRIPTS="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/skills/human-view/scripts"
readonly HV_SCRIPTS_TEXT="\${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/skills/human-view/scripts"
readonly SPACE_LIB_TEXT="\${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/skills/crucible/scripts/lib/crucible-space.sh"
LC_ALL=C
export LC_ALL

usage() {
	cat <<EOF
usage: sh ${PROG} --plan-path
       <renderer> --plan-file PATH | sh ${PROG} --label LABEL [--effort FOLDER]
       <renderer> --plan-file PATH | sh ${PROG} --show-only
       sh ${PROG} --help | -h

Opens this session's approval gate for the rendered plan on stdin and prints
the gate text for the human.

Options:
  --plan-path       print the session's plan file path; opens no gate; takes
                    no other option
  --label LABEL     open a pending gate labelled LABEL, the label the gate's
                    procedure sets (such as dispatch-plan), a Crucible item
                    label (see crucible.sh --help); needed unless
                    --plan-path or --show-only
  --effort FOLDER   the absolute effort folder the gate belongs to, as
                    effort.sh start printed, under
                    \${CRUCIBLE_HOME:-\$HOME/.crucible}/efforts/; where
                    the answer is recorded: see gate-answer-hook.sh --help;
                    pass it only when a script reads the gate's answer
  --show-only       open a gate that shows the plan and asks nothing: a plain
                    card, its question not held; takes no --label or --effort

Environment:
  CLAUDE_CODE_SESSION_ID  the session id Claude Code sets in the Bash tool
  CLAUDE_CONFIG_DIR  the Claude Code config folder; default \$HOME/.claude
  CRUCIBLE_HOME  the Crucible space; its rules: see crucible.sh --help

stdout with --plan-path: one absolute path, the session's plan file
stdout otherwise: the gate text, its last line the gate marker

Writes:
  the gate through human-view's show.sh: a gate LABEL with its effort, or
    with --show-only a card (see show.sh --help)
  under \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/cache/approval-gate/: the
    session's folder, owner-only, which keeps its plan file; other sessions'
    folders unchanged for ${hv_stale_minutes-} minutes are removed; a symbolic link is
    never followed or removed; --plan-path writes no file
Nothing else is left behind (a SIGKILL aside). Exit 2 or 5 leaves
everything as it was.

Exit codes:
  0  done; show the gate text, or (--plan-path) write the plan at the path
  1  the plan or the gate folder could not be processed; show the human
     stderr and the exit code
  2  refused input; fix what stderr names and rerun once, else show the
     human stderr
  4  stdout closed before the gate was written; stop and show the exit code
  5  install fault; show the human stderr, which names what to install
  129, 130, 143  stopped by HUP, INT or TERM; show the human the exit code

Dependencies (a missing one exits 5, named):
  POSIX sh; ${REQUIRED_TOOLS}
    (jq 1.6+: macOS: brew install jq; Linux: the distro's jq package; the
    rest in every macOS and Linux base system; find with -mmin)
  views/gate.jq in this skill (reinstall the procedure-approval-gate skill)
  human-view's show.sh, lib/owed.sh and lib/render.sh,
    ${HV_SCRIPTS_TEXT}
    (install the human-view skill)
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
	[ ! -L "${gate_dir}" ] || die 1 "gate folder is a symbolic link: ${gate_dir}; expected a plain folder; try removing the link, then rerun"
	[ "${action}" != plan-path ] || [ ! -L "${plan_path}" ] ||
		die 1 "plan file is a symbolic link: ${plan_path}; expected a plain file or none; try removing the link, then rerun"
}

# Creates the session's folder with mode 700 and marks it in use (its
# modification time is now, which keeps other sessions' sweeps off it while
# the plan is written), at the gate_dir check_gate_paths set.
make_gate_dir() {
	mkdir -p "${gate_dir}" || die 1 "cannot create the gate folder ${gate_dir}; expected a writable \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/cache; try checking its owner and free space, then rerun"
	chmod 700 "${gate_dir}" || die 1 "cannot set mode 700 on ${gate_dir}; expected a folder your user owns; try checking its owner, then rerun"
	touch "${gate_dir}" || die 1 "cannot set the modification time of ${gate_dir}; expected a folder your user owns; try checking its owner, then rerun"
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
	[ -n "${label}" ] || usage_error "--label missing or empty; expected --label LABEL, the label the gate's procedure sets, such as dispatch-plan"
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
# the space rules. A control character is refused before the path is shown
# on stderr.
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

# Sweeps other sessions' gate folders idle past the store's stale time.
sweep_other_gates() {
	# shellcheck disable=SC2310 # its status says whether every idle folder went; the folder is read below
	hv_sweep_idle "${gate_root}" "${session_id}" ||
		warn "cannot remove the stale gate folder ${hv_sweep_problem}; expected a folder your user owns; left in place; check its owner"
}

# Sets plan_data to the plan on stdin as {plan: TEXT}, or exits 2 when it holds
# nothing but blank lines. Built before any folder exists, so bad input
# writes nothing.
read_plan() {
	plan_data=$(jq -Rs '{plan: .}') || die 1 'jq failed reading the plan; expected jq 1.6+ on PATH; try checking jq, then rerun'
	blank_status=0
	printf '%s' "${plan_data}" | jq -e '.plan | test("[^ \t\n\u000b\f\r]")' >/dev/null || blank_status=$?
	case ${blank_status} in
		0) ;;
		1) usage_error 'empty input; expected the rendered gate plan on stdin; if a renderer was piped in, it printed nothing: check its stderr above; otherwise try piping the renderer into this script' ;;
		*) die 1 "jq failed (exit ${blank_status}) reading the plan; expected jq 1.6+; try checking jq on PATH, then rerun" ;;
	esac
}

# Prints the gate through show.sh, a gate labelled label (with its effort) or,
# with --show-only, a card.
show_gate() {
	shown_label=''
	[ "${gate_state}" != pending ] || shown_label=${label}
	# shellcheck disable=SC2310 # its status names the fault; set -e is not relied on inside
	hv_show_card "${HV_SCRIPTS}/show.sh" "${views_dir}" gate "${effort}" "${plan_data}" "${shown_label}" || {
		[ "${hv_render_status}" -ne 5 ] || exit 5
		die 1 "${hv_render_problem}; expected the gate card printed; show the human that stderr"
	}
}

# Exits 5 unless show.sh, its store rules, its print calls and the gate
# template are installed; the store rules are sourced on start, so --help can
# print their values.
check_human_view() {
	for hv_file in "${HV_SCRIPTS}/lib/render.sh" "${HV_SCRIPTS}/lib/owed.sh"; do
		[ -f "${hv_file}" ] && [ -r "${hv_file}" ] ||
			die 5 "human-view missing; expected ${hv_file}; try installing the human-view skill"
	done
	# shellcheck source=../../../../engine/human-view/scripts/lib/render.sh
	. "${HV_SCRIPTS}/lib/render.sh"
	# shellcheck disable=SC2310 # its status is the answer; set -e is not relied on inside
	hv_check_printer "${HV_SCRIPTS}" "${views_dir}" gate || die 5 "${hv_printer_problem}"
}

case $0 in
	*/*) views_dir="${0%/*}/../views" ;;
	*) views_dir='../views' ;;
esac
if [ -f "${HV_SCRIPTS}/lib/owed.sh" ] && [ -r "${HV_SCRIPTS}/lib/owed.sh" ]; then
	# shellcheck source=../../../../engine/human-view/scripts/lib/owed.sh
	. "${HV_SCRIPTS}/lib/owed.sh"
fi
parse_args "$@"

for tool in ${REQUIRED_TOOLS}; do
	command -v "${tool}" >/dev/null 2>&1 ||
		die 5 "${tool} missing; expected it on PATH; try installing your base system's ${tool}"
done
check_human_view

session_id="${CLAUDE_CODE_SESSION_ID-}"
check_session_id "${session_id}"
umask 077
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [ "${action}" = open ]; then read_plan; fi
check_gate_paths "${session_id}"
make_gate_dir
sweep_other_gates
if [ "${action}" = plan-path ]; then
	printf '%s\n' "${plan_path}"
else
	show_gate
fi
