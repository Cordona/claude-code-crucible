#!/usr/bin/env sh
# Prints the iteration a seat is working on, where its report draft goes and
# the event of its newest recorded report and whether that report is done (the
# one done test). The iteration is derived from git: the seat's next build is
# 1 + its own build commits since its base. It reads only; with --checked it
# also prints, for the human, that done state.
# shellcheck source-path=SCRIPTDIR source-path=SCRIPTDIR/../../../../../../../../framework/core/engine/human-view/scripts/lib
set -eu

readonly PROG='iteration.sh'
readonly CRUCIBLE_SKILL='crucible'
# The C locale keeps the shell byte-wise.
LC_ALL=C
export LC_ALL
GIT_OPTIONAL_LOCKS=0
GIT_TERMINAL_PROMPT=0
export GIT_OPTIONAL_LOCKS GIT_TERMINAL_PROMPT
# An inherited repository override would make git read outside the worktree.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
	GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_PREFIX

usage() {
	cat <<EOF
usage: sh ${PROG} --effort FOLDER --seat S [--checked TASK]
       sh ${PROG} --help | -h

Prints the iteration seat S is working on, its report draft's path, its
newest recorded report and whether that report is done; reads only.

--effort FOLDER  the effort folder, absolute
--seat S      a seat with a worktree; it may be open or bound, not chosen
              (no worktree yet)
--checked TASK
              also print the line checked_earlier for the seat's part TASK

stdout, four lines:
  ITERATION: <N>   1 + the crucible(build) commits in <base>..HEAD of the
                   worktree whose Agent-Seat trailer is S, the iteration its
                   next build commit opens
  REPORT: <path>   <effort>/drafts/agents/<S>/report.json, absolute
  LAST_REPORT: <path> | none
                   the seat's newest build.committed event, absolute; none
                   when there is none
  LAST_REPORT_STATE: done | blocked
                   done when LAST_REPORT's body lists no blockers, else
                   blocked (also with none)
with --checked, then the line checked_earlier (views/lines.jq) with that
  state, printed by human-view's show.sh and recorded as owed this session
  (CLAUDE_CODE_SESSION_ID) for --effort

exit codes:
  0  printed
  2  wrong command line: a missing, repeated or unknown option, or a
     missing value
  3  input: the effort, the seat, its worktree or its base does not fit,
     or the seat is chosen;
     one stderr line per problem (seats.sh's own lines first when it
     refused)
  4  environment: git, jq, seats.sh or events.sh missing or failed, or the
     report event unreadable (nothing printed); with --checked, also the
     printer missing, or show.sh failed after the four lines (stderr says so)

needs: POSIX sh, git 2.26+, jq 1.6+; seats.sh beside this script; the
${CRUCIBLE_SKILL} skill's events.sh; with --checked:
../cards/cards-lib.sh from this script's folder, this skill's views/ and
human-view's scripts/show.sh and scripts/lib/render.sh in
${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/skills/human-view
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
	printf "Try 'sh %s --help'.\n" "${PROG}" >&2
	exit 2
}

# Prints $1 with each control character as "?", so a value can't split a stderr line.
printable() {
	printf '%s' "$1" | tr '[:cntrl:]' '?'
}

# Sets $option_value from "$1 $2", refusing a repeat or a missing value.
take_value() {
	[ -n "$3" ] || usage_error "$1 needs a value; expected $1 $4"
	[ -z "$2" ] || usage_error "$1 given twice; expected one"
	option_value=$3
}

parse_args() {
	effort_folder='' seat='' checked_task=''
	while [ "$#" -gt 0 ]; do
		case $1 in
			-h | --help)
				usage
				exit 0
				;;
			--effort)
				take_value "$1" "${effort_folder}" "${2-}" FOLDER
				effort_folder=${option_value}
				;;
			--seat)
				take_value "$1" "${seat}" "${2-}" S
				seat=${option_value}
				;;
			--checked)
				take_value "$1" "${checked_task}" "${2-}" TASK
				checked_task=${option_value}
				;;
			*)
				shown_option=$(printable "$1")
				usage_error "unknown option: ${shown_option}; expected --effort, --seat, --checked or --help"
				;;
		esac
		shift 2
	done
	[ -n "${effort_folder}" ] || usage_error '--effort missing; expected --effort FOLDER'
	while [ "${effort_folder}" != "${effort_folder%/}" ]; do effort_folder=${effort_folder%/}; done
	[ -n "${seat}" ] || usage_error '--seat missing; expected --seat S'
}

script_dir() {
	case $0 in
		*/*) printf '%s' "${0%/*}" ;;
		*) printf '.' ;;
	esac
}

load_dependencies() {
	command -v git >/dev/null 2>&1 || die 4 'git not found; expected git 2.26+ on PATH'
	command -v jq >/dev/null 2>&1 || die 4 'jq not found; expected jq 1.6+ on PATH'
	own_path=$(script_dir)
	own_dir=$(cd -P -- "${own_path}" && pwd -P) || die 4 "this script's folder could not be entered"
	[ -f "${own_dir}/seats.sh" ] || die 4 'seats.sh not found beside this script; expected both in one folder'
	events_script="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/skills/${CRUCIBLE_SKILL}/scripts/events.sh"
	[ -f "${events_script}" ] || die 4 "events.sh not found; expected the ${CRUCIBLE_SKILL} skill installed"
	[ -z "${checked_task}" ] || load_printer
}

# Sources ../cards/cards-lib.sh and checks the line printer it loads.
load_printer() {
	[ -f "${own_dir}/../cards/cards-lib.sh" ] ||
		die 4 "../cards/cards-lib.sh not found from ${PROG}'s folder; expected the procedure's scripts folders whole"
	# shellcheck source=../cards/cards-lib.sh
	. "${own_dir}/../cards/cards-lib.sh"
	# shellcheck disable=SC2310 # its status names the fault; set -e is not relied on inside
	card_load_printer lines || die 4 "${card_problem}"
}

# Sets worktree and base from seats.sh get, refusing a chosen seat;
# seats.sh's own lines say why it refused.
read_seat() {
	seat_rc=0
	seat_json=$(sh "${own_dir}/seats.sh" get --effort "${effort_folder}" --seat "${seat}") || seat_rc=$?
	shown_seat=$(printable "${seat}")
	case ${seat_rc} in
		0) ;;
		2 | 3 | 6) die 3 "seats.sh get refused seat ${shown_seat} (exit ${seat_rc}); expected a seat of --effort" ;;
		*) die 4 "seats.sh get failed (exit ${seat_rc})" ;;
	esac
	fields=$(printf '%s\n' "${seat_json}" | jq -r '.status // "", .worktree // "", .base // ""') ||
		die 4 'jq could not read the seat seats.sh get printed'
	status='' worktree='' base=''
	{
		IFS= read -r status || :
		IFS= read -r worktree || :
		IFS= read -r base || :
	} <<EOF
${fields}
EOF
	[ "${status}" != chosen ] || die 3 "seat ${shown_seat} is chosen: its worktree is not made yet; expected an open or bound seat"
	[ -n "${worktree}" ] || die 3 "seat ${shown_seat} has no worktree; expected a seat with a worktree"
}

# Sets iteration from the seat's own build commits in the worktree's
# base..HEAD.
count_iteration() {
	shown_worktree=$(printable "${worktree}")
	[ -d "${worktree}" ] || die 3 "seat ${shown_seat}'s worktree ${shown_worktree} is not a folder; expected its git worktree"
	git -c core.fsmonitor=false -C "${worktree}" rev-parse --verify --quiet "${base}^{commit}" >/dev/null ||
		die 3 "seat ${shown_seat}'s base ${base} is not a commit in ${shown_worktree}; expected the seat's base"
	build_lines=$(git -c core.fsmonitor=false -C "${worktree}" log \
		--format='%s%x09%(trailers:key=Agent-Seat,valueonly,separator=%x2C)' "${base}..HEAD") ||
		die 4 "git log failed in ${shown_worktree}"
	own_builds=0
	tab=$(printf '\t')
	while IFS= read -r line; do
		case ${line} in
			"crucible(build): "*) ;;
			*) continue ;;
		esac
		[ "${line#*"${tab}"}" != "${seat}" ] || own_builds=$((own_builds + 1))
	done <<EOF
${build_lines}
EOF
	iteration=$((own_builds + 1))
}

# Sets last_report to the seat's newest build.committed event.
find_last_report() {
	last_report=$(sh "${events_script}" latest --effort "${effort_folder}" --type build.committed \
		--where ".seat == \"${seat}\"" </dev/null) ||
		die 4 'events.sh latest failed (its stderr is above)'
}

# Sets report_state to done when the last report lists no blockers, else
# blocked.
read_report_state() {
	report_state=blocked
	[ -n "${last_report}" ] || return 0
	shown_report=$(printable "${last_report}")
	report_done=$(jq -r '(.body.blockers // []) | length == 0' "${last_report}" </dev/null) ||
		die 4 "jq could not read the report event ${shown_report}"
	[ "${report_done}" != true ] || report_state='done'
}

parse_args "$@"
load_dependencies
read_seat
count_iteration
find_last_report
read_report_state
printf 'ITERATION: %s\nREPORT: %s/drafts/agents/%s/report.json\n' \
	"${iteration}" "${effort_folder}" "${seat}"
printf 'LAST_REPORT: %s\nLAST_REPORT_STATE: %s\n' "${last_report:-none}" "${report_state}"
# shellcheck disable=SC2310 # its status names the fault; set -e is not relied on inside
[ -z "${checked_task}" ] ||
	hv_show_line "${card_show}" "${card_views}" checked_earlier "${effort_folder}" \
		--arg state "${report_state}" --arg task "${checked_task}" ||
	die 4 "${hv_render_problem}; the four lines are printed, the line checked_earlier not shown"
