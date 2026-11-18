#!/usr/bin/env sh
# Moves a seat onto another commit for new work: its worktree's branch is
# reset to the commit and the seat's base becomes that commit. It only runs
# seats.sh and worktree-move.sh in order; when seats.sh refuses after the
# worktree moved, the worktree is moved back to its old HEAD and the ref
# that kept it is deleted. Its card is views/seat-moved.jq, printed by
# human-view's show.sh.
# shellcheck source-path=SCRIPTDIR source-path=SCRIPTDIR/../../../../../../../../framework/core/engine/human-view/scripts/lib
set -eu
umask 077

readonly PROG='seat-move.sh'
readonly VIEW_LIB='human-view'
# The C locale keeps the shell byte-wise.
LC_ALL=C
export LC_ALL
GIT_OPTIONAL_LOCKS=0
GIT_TERMINAL_PROMPT=0
export GIT_OPTIONAL_LOCKS GIT_TERMINAL_PROMPT
# An inherited repository override would make git act outside the seat's repo.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
	GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_PREFIX

usage() {
	cat <<EOF
usage: sh ${PROG} --effort DIR --seat S --to COMMIT [--follows NAME]
       sh ${PROG} --help | -h

Points a seat's worker branch at COMMIT and makes COMMIT the seat's base,
writing its seat.moved event; the bound agent stays bound. When the branch
holds commits COMMIT lacks, its old HEAD is first kept under
refs/crucible/moved/<effort folder name>/S/<n>, n from 1, in the seat's
repository, so that work stays reachable. A refusal changes nothing; a
failure after the branch moved puts the branch, the ref and the seat back,
unless putting them back fails too (exit 4, stderr names the undo). The
main checkout's working tree and branches are never touched. Nothing else
is left behind (a SIGKILL aside).

--effort DIR    absolute path of the effort folder
--seat S        a build seat with a worktree, not working, its tester not
                working; a tester seat is refused (its base is its build
                seat's)
--to COMMIT     a sha or a ref of the seat's repo (a branch, a
                remote-tracking branch, a tag); not starting with -
--follows NAME  the branch the commit was taken from, for the human;
                default: COMMIT when it is a ref, not a sha

stdout: the seat's JSON line, as seats.sh get prints it; then the card
  seat-moved (views/seat-moved.jq), printed by ${VIEW_LIB}'s show.sh and
  recorded as owed this session (CLAUDE_CODE_SESSION_ID)

exit codes:
  0  moved; go on
  2  wrong command line; fix what stderr names
  3  refused input, nothing changed; show the human stderr, and stop
  4  a dependency or a step failed; show the human stderr, and stop
  5  refused by state, nothing changed; show the human stderr, and stop
  129, 130, 143  stopped by HUP, INT or TERM; show the human the exit code

needs: POSIX sh, git 2.31+, jq 1.6+; ../worktree/worktree-move.sh and
../cards/cards-lib.sh from this script's folder; procedure-seat-run's
seats/seats.sh beside procedure-git-worktree; this
skill's views/; ${VIEW_LIB}'s scripts/show.sh and
scripts/lib/render.sh in ${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/skills/${VIEW_LIB}
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
	effort='' seat='' to='' follows=''
	while [ "$#" -gt 0 ]; do
		case $1 in
			-h | --help)
				usage
				exit 0
				;;
			--effort)
				take_value "$1" "${effort}" "${2-}" DIR
				effort=${option_value}
				;;
			--seat)
				take_value "$1" "${seat}" "${2-}" S
				seat=${option_value}
				;;
			--to)
				take_value "$1" "${to}" "${2-}" COMMIT
				to=${option_value}
				;;
			--follows)
				take_value "$1" "${follows}" "${2-}" NAME
				follows=${option_value}
				;;
			*)
				shown_option=$(printable "$1")
				usage_error "unknown option: ${shown_option}; expected --effort, --seat, --to, --follows or --help"
				;;
		esac
		shift 2
	done
	[ -n "${effort}" ] || usage_error '--effort missing; expected --effort DIR'
	[ -n "${seat}" ] || usage_error '--seat missing; expected --seat S'
	[ -n "${to}" ] || usage_error '--to missing; expected --to COMMIT'
}

script_dir() {
	case $0 in
		*/*) printf '%s' "${0%/*}" ;;
		*) printf '.' ;;
	esac
}

load_dependencies() {
	command -v git >/dev/null 2>&1 || die 4 'git not found; expected git 2.31+ on PATH'
	command -v jq >/dev/null 2>&1 || die 4 'jq not found; expected jq 1.6+ on PATH'
	own_path=$(script_dir)
	own_dir=$(cd -P -- "${own_path}" && pwd -P) || die 4 "this script's folder could not be entered"
	for step in ../worktree/worktree-move.sh ../../../procedure-seat-run/scripts/seats/seats.sh ../cards/cards-lib.sh; do
		[ -f "${own_dir}/${step}" ] || {
			shown_step=$(printable "${own_dir}/${step}")
			whole="the procedure's scripts folders whole"
			case ${step} in ../../../procedure-seat-run/*) whole='procedure-seat-run installed beside procedure-git-worktree' ;; *) ;; esac
			die 4 "${shown_step} not found; expected ${whole}"
		}
	done
	# shellcheck source=../cards/cards-lib.sh
	. "${own_dir}/../cards/cards-lib.sh"
	# shellcheck disable=SC2310 # its status names the fault; set -e is not relied on inside
	card_load_printer seat-moved || die 4 "${card_problem}"
}

# Sets effort_name, the effort folder's name with symlinks resolved, as
# seat-open.sh names the branch, refusing an effort path that is not
# absolute and a --follows holding a control character.
check_inputs() {
	shown_effort=$(printable "${effort}")
	case ${effort} in
		/*) ;;
		*) die 3 "--effort ${shown_effort} is not absolute; expected an absolute path" ;;
	esac
	effort_dir=$(cd -P -- "${effort}" 2>/dev/null && pwd -P) ||
		die 3 "--effort ${shown_effort} is not a folder; expected the effort folder"
	effort_name=${effort_dir##*/}
	case ${follows} in
		*[[:cntrl:]]*)
			shown_follows=$(printable "${follows}")
			die 3 "--follows ${shown_follows} holds a control character; expected a branch name"
			;;
		*) ;;
	esac
}

# Sets status, repo, worktree, role and build_seat from the seat; seats.sh's
# own lines say why it refused.
read_seat() {
	step_rc=0
	seat_json=$(sh "${own_dir}/../../../procedure-seat-run/scripts/seats/seats.sh" get --effort "${effort}" --seat "${seat}") || step_rc=$?
	shown_seat=$(printable "${seat}")
	case ${step_rc} in
		0) ;;
		6) die 3 "seat ${shown_seat} is not in ${shown_effort}; expected a seat of the effort" ;;
		2 | 3) die 3 "seats.sh get refused seat ${shown_seat} (exit ${step_rc}); expected a seat in ${shown_effort}" ;;
		*) die 4 "seats.sh get failed (exit ${step_rc}; its stderr is above); expected the seat's JSON line; fix what it names and rerun" ;;
	esac
	fields=$(printf '%s\n' "${seat_json}" | jq -r '.status // "", .repo // "", .worktree // "", .role // "", .build_seat // ""') ||
		die 4 "jq could not read the seat seats.sh get printed; expected one JSON line; try sh procedure-seat-run's scripts/seats/seats.sh get --effort ${shown_effort} --seat ${shown_seat}"
	status='' repo='' worktree='' role='' build_seat=''
	{
		IFS= read -r status || :
		IFS= read -r repo || :
		IFS= read -r worktree || :
		IFS= read -r role || :
		IFS= read -r build_seat || :
	} <<EOF
${fields}
EOF
	shown_worktree=$(printable "${worktree}")
}

# Refuses a tester seat, as seats.sh move does, before anything moves.
check_role() {
	[ "${role}" = tester ] || return 0
	shown_build_seat=$(printable "${build_seat}")
	die 3 "seat ${shown_seat} is a tester seat: its base is its build seat ${shown_build_seat}'s; expected a build seat"
}

# Refuses a seat that has no worktree yet, whose agent is busy, or whose
# tester is working: never two agents in one worktree.
check_status() {
	case ${status} in
		chosen) die 5 "seat ${shown_seat} is chosen: its worktree is not made yet; expected a seat with a worktree" ;;
		working) die 5 "seat ${shown_seat} is working: its ${role} is busy; expected it idle, open or gave-up" ;;
		*) ;;
	esac
	check_pair_idle
}

# Refuses the seat while its tester, sharing its worktree, is working.
check_pair_idle() {
	run_step ../../../procedure-seat-run/scripts/seats/seats.sh list --effort "${effort}"
	[ "${step_rc}" -eq 0 ] ||
		die 4 "seats.sh list failed (exit ${step_rc}; its stderr is above); expected the effort's seat list; fix what it names and rerun"
	busy_pair=$(printf '%s\n' "${step_out}" | jq -r --arg seat "${seat}" '
		first(.seats[] | select(.build_seat == $seat and .status == "working") | .seat)') ||
		die 4 'jq could not read the seat list seats.sh list printed; expected one JSON line'
	[ -n "${busy_pair}" ] || return 0
	shown_pair=$(printable "${busy_pair}")
	die 5 "seat ${shown_seat} shares its worktree with seat ${shown_pair}, which is working; expected no agent working in the worktree"
}

# Sets to_sha, the full sha --to names in the seat's repo, and follows to
# --to when it is a ref and no --follows was given.
resolve_target() {
	shown_to=$(printable "${to}")
	case ${to} in
		-*) die 3 "--to ${shown_to} starts with -; expected a sha or a ref of the seat's repo" ;;
		*[[:cntrl:]]*) die 3 "--to ${shown_to} holds a control character; expected a sha or a ref of the seat's repo" ;;
		*) ;;
	esac
	shown_repo=$(printable "${repo}")
	to_sha=$(git -C "${repo}" -c core.fsmonitor=false rev-parse --verify --quiet --end-of-options "${to}^{commit}" 2>/dev/null) ||
		die 3 "--to ${shown_to} is no commit or ref of the seat's repo ${shown_repo}; expected a sha, branch, remote-tracking branch or tag (fetch it first)"
	[ -z "${follows}" ] || return 0
	case ${to_sha} in
		"${to}"*) ;;
		*) follows=${to} ;;
	esac
}

# Runs step $1, a path from this script's folder, with the rest as
# arguments; its stdout in step_out, its exit code in step_rc; its stderr
# passes through.
run_step() {
	step_rc=0
	step_script=$1
	shift
	step_out=$(sh "${own_dir}/${step_script}" "$@") || step_rc=$?
}

# Exit code 3 when step refused its input, 5 when its state, else 4.
step_exit_code() {
	case ${step_rc} in
		3 | 5) step_exit=${step_rc} ;;
		*) step_exit=4 ;;
	esac
}

# Sets keep_ref, the first refs/crucible/moved/<effort>/<seat>/<n> the seat's
# repository lacks; n counts the seat's moves that kept a HEAD.
name_keep_ref() {
	keep_prefix="refs/crucible/moved/${effort_name}/${seat}"
	kept_refs=$(git -C "${repo}" for-each-ref --format='%(refname)' "${keep_prefix}/" 2>/dev/null) ||
		die 4 "git for-each-ref failed in the seat's repo ${shown_repo}; expected it to list ${keep_prefix}/"
	last=0
	while IFS= read -r kept_ref; do
		number=${kept_ref##*/}
		case ${number} in
			'' | *[!0123456789]*) ;;
			*) [ "${number}" -le "${last}" ] || last=${number} ;;
		esac
	done <<EOF
${kept_refs}
EOF
	keep_ref="${keep_prefix}/$((last + 1))"
}

# Sets old_head, and kept to the ref worktree-move.sh kept it under (empty
# when the move left no commit out).
move_worktree() {
	run_step ../worktree/worktree-move.sh --worktree "${worktree}" --to "${to_sha}" --keep-as "${keep_ref}"
	step_exit_code
	[ "${step_rc}" -eq 0 ] ||
		die "${step_exit}" "worktree-move.sh failed (exit ${step_rc}; its stderr is above): nothing was changed; fix what it names and rerun"
	old_head='' kept=''
	while IFS= read -r line; do
		case ${line} in
			'old-head '*) old_head=${line#old-head } ;;
			'kept '*) kept=${line#kept } ;;
			*) ;;
		esac
	done <<EOF
${step_out}
EOF
	[ -n "${old_head}" ] || die 4 "worktree-move.sh printed no old-head line; expected one: the worktree may be moved; check git -C ${shown_worktree} reflog"
}

record_move() {
	run_step ../../../procedure-seat-run/scripts/seats/seats.sh move --effort "${effort}" --seat "${seat}" --base "${to_sha}"
	[ "${step_rc}" -ne 0 ] || return 0
	step_exit_code
	move_rc=${step_rc}
	run_step ../worktree/worktree-move.sh --worktree "${worktree}" --to "${old_head}"
	[ "${step_rc}" -eq 0 ] ||
		die 4 "seats.sh move failed (exit ${move_rc}) and moving the worktree back failed (exit ${step_rc}); run git -C ${shown_worktree} reset --keep ${old_head} to undo the move"
	drop_kept_ref
	die "${step_exit}" "seats.sh move failed (exit ${move_rc}; its stderr is above); moved the worktree back to its old HEAD ${old_head}: nothing changed; fix what it names and rerun"
}

# Deletes the ref that kept the old HEAD, once the worktree is back on it.
drop_kept_ref() {
	[ -n "${kept}" ] || return 0
	git -C "${repo}" -c core.hooksPath=/dev/null update-ref -d "${kept}" "${old_head}" 2>/dev/null ||
		die 4 "seats.sh move failed and the worktree is back on ${old_head}, but ${kept} could not be deleted; run git -C ${shown_repo} update-ref -d ${kept}"
}

# Prints the seat, then its card.
print_result() {
	run_step ../../../procedure-seat-run/scripts/seats/seats.sh get --effort "${effort}" --seat "${seat}"
	[ "${step_rc}" -eq 0 ] ||
		die 4 "seats.sh get failed (exit ${step_rc}; its stderr is above) after the seat was moved: the seat is moved; expected its JSON line; run sh procedure-seat-run's scripts/seats/seats.sh get --effort ${shown_effort} --seat ${shown_seat}"
	printf '%s\n' "${step_out}"
	card_data=$(jq -nc --arg seat "${seat}" --arg commit "${to_sha}" --arg follows "${follows}" \
		'{seat: $seat, commit: $commit, follows: $follows}') ||
		die 4 'jq could not build the card'\''s data; the seat is moved; expected jq 1.6+'
	# shellcheck disable=SC2310 # its status names the fault; set -e is not relied on inside
	hv_show_card "${card_show}" "${card_views}" seat-moved "${effort}" "${card_data}" ||
		die 4 "${hv_render_problem}; the seat is moved, its card not shown"
}

parse_args "$@"
load_dependencies
check_inputs
read_seat
check_role
check_status
resolve_target
name_keep_ref
move_worktree
record_move
print_result
