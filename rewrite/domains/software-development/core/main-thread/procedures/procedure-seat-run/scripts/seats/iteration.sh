#!/usr/bin/env sh
# Prints the iteration a seat is working on, where its report draft goes and
# the event of its newest recorded report and whether that report is done (the
# one done test). The iteration is derived from git: a build seat's next build
# is 1 + its own build commits since its base; a tester seat works in its
# build seat's current iteration and never opens one. It reads only; with
# --checked it also prints, for the human, that done state.
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

Prints the iteration seat S is working on, its report draft's path (a
tester's plan draft's too), its newest recorded report and whether that
report is done; reads only.

--effort FOLDER  the effort folder, absolute
--seat S      a seat with a worktree; it may be open or bound, not chosen
              (no worktree yet)
--checked TASK
              also print the line checked_earlier for the seat's part TASK

stdout of a build seat, four lines:
  ITERATION: <N>   1 + the crucible(build) commits in <base>..HEAD of the
                   worktree whose Agent-Seat trailer is S, the iteration its
                   next build commit opens
  REPORT: <path>   <effort>/drafts/agents/<S>/report.json, absolute
  LAST_REPORT: <path> | none
                   the seat's newest build.committed event, absolute; none
                   when there is none
  LAST_REPORT_STATE: done | blocked
                   done when LAST_REPORT's body lists no blockers, or only
                   gate_red ones and its tester's (test-agent-<letter>)
                   newest test.committed is later and lists none; else
                   blocked (also with none)
stdout of a tester seat, five lines:
  ITERATION: <N>   the crucible(build) commits in <base>..HEAD whose
                   Agent-Seat trailer is its build seat: the build seat's
                   current iteration, which a test commit joins
  REPORT: <path>   <effort>/drafts/agents/<S>/report.json, the test report
  PLAN: <path>     <effort>/drafts/agents/<S>/test-plan.json, the plan draft
  LAST_REPORT: <path> | none
                   the seat's newest test-plan.made or test.committed event
  LAST_REPORT_STATE: planned | done | blocked
                   planned when it is a test-plan.made with no blocker, done
                   when a test.committed listing no blockers, or only
                   production_bug ones and its build seat's newest
                   build.committed is later and lists none; else blocked
                   (also with none)
with --checked, then the line checked_earlier (views/lines.jq) with that
  state, printed by human-view's show.sh and recorded as owed this session
  (CLAUDE_CODE_SESSION_ID) for --effort

exit codes:
  0  printed
  2  wrong command line: a missing, repeated or unknown option, or a
     missing value
  3  input: the effort, the seat, its worktree or its base does not fit,
     the seat is chosen, or a tester's build seat has no build commit yet;
     one stderr line per problem (seats.sh's own lines first when it
     refused)
  4  environment: git, jq, seats.sh or events.sh missing or failed, or the
     report event unreadable (nothing printed); with --checked, also the
     printer missing, or show.sh failed after the four lines (a builder's)
     or five (a tester's) (stderr says so)

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

# Sets role, build_seat, worktree and base from seats.sh get, refusing a
# chosen seat; seats.sh's own lines say why it refused.
read_seat() {
	seat_rc=0
	seat_json=$(sh "${own_dir}/seats.sh" get --effort "${effort_folder}" --seat "${seat}") || seat_rc=$?
	shown_seat=$(printable "${seat}")
	case ${seat_rc} in
		0) ;;
		2 | 3 | 6) die 3 "seats.sh get refused seat ${shown_seat} (exit ${seat_rc}); expected a seat of --effort" ;;
		*) die 4 "seats.sh get failed (exit ${seat_rc})" ;;
	esac
	fields=$(printf '%s\n' "${seat_json}" | jq -r '.role // "", .build_seat // "", .status // "", .worktree // "", .base // ""') ||
		die 4 'jq could not read the seat seats.sh get printed'
	role='' build_seat='' status='' worktree='' base=''
	{
		IFS= read -r role || :
		IFS= read -r build_seat || :
		IFS= read -r status || :
		IFS= read -r worktree || :
		IFS= read -r base || :
	} <<EOF
${fields}
EOF
	[ "${status}" != chosen ] || die 3 "seat ${shown_seat} is chosen: its worktree is not made yet; expected an open or bound seat"
	[ -n "${worktree}" ] || die 3 "seat ${shown_seat} has no worktree; expected a seat with a worktree"
}

# Sets iteration from the build commits in the worktree's base..HEAD: a build
# seat's own plus one, a tester's build seat's, refused when none.
count_iteration() {
	shown_worktree=$(printable "${worktree}")
	[ -d "${worktree}" ] || die 3 "seat ${shown_seat}'s worktree ${shown_worktree} is not a folder; expected its git worktree"
	git -c core.fsmonitor=false -C "${worktree}" rev-parse --verify --quiet "${base}^{commit}" >/dev/null ||
		die 3 "seat ${shown_seat}'s base ${base} is not a commit in ${shown_worktree}; expected the seat's base"
	build_lines=$(git -c core.fsmonitor=false -C "${worktree}" log \
		--format='%s%x09%(trailers:key=Agent-Seat,valueonly,separator=%x2C)' "${base}..HEAD") ||
		die 4 "git log failed in ${shown_worktree}"
	building_seat=${seat}
	[ "${role}" != tester ] || building_seat=${build_seat}
	builds=0
	tab=$(printf '\t')
	while IFS= read -r line; do
		case ${line} in
			"crucible(build): "*) ;;
			*) continue ;;
		esac
		[ "${line#*"${tab}"}" != "${building_seat}" ] || builds=$((builds + 1))
	done <<EOF
${build_lines}
EOF
	if [ "${role}" != tester ]; then
		iteration=$((builds + 1))
		return 0
	fi
	shown_build_seat=$(printable "${building_seat}")
	[ "${builds}" -gt 0 ] ||
		die 3 "seat ${shown_seat}'s build seat ${shown_build_seat} has no build commit yet; expected a build to test"
	iteration=${builds}
}

# Sets last_report to the seat's newest result event: a build seat's
# build.committed, a tester's test-plan.made or test.committed.
find_last_report() {
	set -- --type build.committed --where ".seat == \"${seat}\""
	[ "${role}" != tester ] ||
		set -- --type 'test*' --where ".seat == \"${seat}\" and (.type == \"test-plan.made\" or .type == \"test.committed\")"
	last_report=$(sh "${events_script}" latest --effort "${effort_folder}" "$@" </dev/null) ||
		die 4 'events.sh latest failed (its stderr is above)'
}

# Sets report_state to done when the last report lists no blockers, planned
# when it is a plan with no blocker, else blocked; a tester's tests that
# found only production bugs are done once its build seat fixed them, and a
# build that turned only existing tests red once its tester updated them.
read_report_state() {
	report_state=blocked
	[ -n "${last_report}" ] || return 0
	shown_report=$(printable "${last_report}")
	report_state=$(jq -r 'def only($kind): (.body.blockers | type) == "array"
			and all(.body.blockers[]; type == "object" and .kind == $kind);
		if .type == "test-plan.made" then (if .body.blocker == null then "planned" else "blocked" end)
		elif (.body.blockers // []) | length == 0 then "done"
		elif .type == "test.committed" and only("production_bug") then "bugs \(.seq)"
		elif .type == "build.committed" and only("gate_red") then "reds \(.seq)"
		else "blocked" end' "${last_report}" </dev/null) ||
		die 4 "jq could not read the report event ${shown_report}"
	case ${report_state} in
		"bugs "*) read_pair_fix_state build.committed "${build_seat}" "${report_state#bugs }" ;;
		"reds "*)
			name_tester_seat
			read_pair_fix_state test.committed "${tester_seat}" "${report_state#reds }"
			;;
		*) ;;
	esac
}

# Sets tester_seat to the build seat's tester: the tester prefix and its letter.
name_tester_seat() {
	tester_seat=$(jq -nr -L "${own_dir}" --arg seat "${seat}" \
		'include "seats"; "\(seats_prefixes.tester)-\($seat | ltrimstr("\(seats_prefixes.builder)-"))"' </dev/null) ||
		die 4 'jq could not name the tester seat; expected seats.jq beside this script'
}

# Sets report_state to done when the other seat of the pair, $2, has a newest
# $1 event (build.committed or test.committed) that comes after the report
# with seq $3 and lists no blockers, else blocked.
read_pair_fix_state() {
	report_state=blocked
	pair_role=${1%%.*}
	pair_where=$(jq -nr --arg seat "$2" '".seat == \($seat | tojson)"') ||
		die 4 "jq could not quote the ${pair_role} seat"
	last_fix=$(sh "${events_script}" latest --effort "${effort_folder}" --type "$1" --where "${pair_where}" </dev/null) ||
		die 4 'events.sh latest failed (its stderr is above)'
	[ -n "${last_fix}" ] || return 0
	shown_fix=$(printable "${last_fix}")
	report_state=$(jq -r --argjson reported "$3" \
		'if .seq > $reported and ((.body.blockers // []) | length == 0) then "done" else "blocked" end' "${last_fix}" </dev/null) ||
		die 4 "jq could not read the ${pair_role} event ${shown_fix}"
}

parse_args "$@"
load_dependencies
read_seat
count_iteration
find_last_report
read_report_state
printf 'ITERATION: %s\nREPORT: %s/drafts/agents/%s/report.json\n' \
	"${iteration}" "${effort_folder}" "${seat}"
[ "${role}" != tester ] || printf 'PLAN: %s/drafts/agents/%s/test-plan.json\n' "${effort_folder}" "${seat}"
printf 'LAST_REPORT: %s\nLAST_REPORT_STATE: %s\n' "${last_report:-none}" "${report_state}"
# shellcheck disable=SC2310 # its status names the fault; set -e is not relied on inside
[ -z "${checked_task}" ] ||
	hv_show_line "${card_show}" "${card_views}" checked_earlier "${effort_folder}" \
		--arg state "${report_state}" --arg task "${checked_task}" ||
	die 4 "${hv_render_problem}; the seat's lines are printed, the line checked_earlier not shown"
