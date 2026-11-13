#!/usr/bin/env sh
# Moves a seat onto another commit for new work: its worktree's branch is
# reset to the commit and the seat's base becomes that commit. It only runs
# seats.sh and worktree-move.sh in order; when seats.sh refuses after the
# worktree moved, the worktree is moved back to its old HEAD and the ref
# that kept it is deleted.
set -eu
umask 077

readonly PROG='seat-move.sh'
readonly VIEW_LIB='human-view'
# The line shows this many characters of the commit's sha.
readonly SHORT_SHA_LENGTH=7
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
--seat S        a seat with a worktree, not working
--to COMMIT     a sha or a ref of the seat's repo (a branch, a
                remote-tracking branch, a tag); not starting with -
--follows NAME  the branch the commit was taken from, for the human;
                default: COMMIT when it is a ref, not a sha

stdout: the seat's JSON line, as seats.sh get prints it; then the line for
  the human, relayed

exit codes:
  0  moved; relay the second line
  2  wrong command line; fix what stderr names
  3  refused input, nothing changed; show the human stderr, and stop
  4  a dependency or a step failed; show the human stderr, and stop
  5  refused by state, nothing changed; show the human stderr, and stop

needs: POSIX sh, git 2.31+, jq 1.6+; seats.sh, seats.jq and
../worktree/worktree-move.sh from this script's folder; ${VIEW_LIB}'s
view.jq and title.jq in ${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/skills/${VIEW_LIB}
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
	for step in ../worktree/worktree-move.sh seats.sh seats.jq; do
		[ -f "${own_dir}/${step}" ] || {
			shown_step=$(printable "${own_dir}/${step}")
			die 4 "${shown_step} not found; expected the procedure's scripts folders whole"
		}
	done
	view_dir="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/skills/${VIEW_LIB}"
	for module in view.jq title.jq; do
		[ -f "${view_dir}/${module}" ] || {
			shown_view_dir=$(printable "${view_dir}")
			die 4 "${module} not found in ${shown_view_dir}; expected the ${VIEW_LIB} skill installed"
		}
	done
}

# Sets effort_name, the effort folder's name with symlinks resolved, as
# seat-open.sh names the branch, refusing an effort path that is not
# absolute.
check_inputs() {
	shown_effort=$(printable "${effort}")
	case ${effort} in
		/*) ;;
		*) die 3 "--effort ${shown_effort} is not absolute; expected an absolute path" ;;
	esac
	effort_dir=$(cd -P -- "${effort}" 2>/dev/null && pwd -P) ||
		die 3 "--effort ${shown_effort} is not a folder; expected the effort folder"
	effort_name=${effort_dir##*/}
}

# Refuses a --follows seats.sh would refuse after the worktree moved.
check_follows() {
	[ -n "${follows}" ] || return 0
	follows_problem=$(jq -nr -L "${own_dir}" --arg name "${follows}" 'include "seats"; $name | seats_branch_problem' </dev/null) ||
		die 4 'jq failed checking --follows; expected jq 1.6+ and seats.jq'
	[ -z "${follows_problem}" ] || {
		shown_problem=$(printable "${follows_problem}")
		die 3 "--follows ${shown_problem}"
	}
}

# Sets status, repo and worktree from the seat; seats.sh's own lines say why
# it refused.
read_seat() {
	step_rc=0
	seat_json=$(sh "${own_dir}/seats.sh" get --effort "${effort}" --seat "${seat}") || step_rc=$?
	shown_seat=$(printable "${seat}")
	case ${step_rc} in
		0) ;;
		6) die 3 "seat ${shown_seat} is not in ${shown_effort}; expected a seat of the effort" ;;
		2 | 3) die 3 "seats.sh get refused seat ${shown_seat} (exit ${step_rc}); expected a seat in ${shown_effort}" ;;
		*) die 4 "seats.sh get failed (exit ${step_rc}; its stderr is above); expected the seat's JSON line; fix what it names and rerun" ;;
	esac
	fields=$(printf '%s\n' "${seat_json}" | jq -r '.status // "", .repo // "", .worktree // ""') ||
		die 4 "jq could not read the seat seats.sh get printed; expected one JSON line; try sh seats.sh get --effort ${shown_effort} --seat ${shown_seat}"
	status='' repo='' worktree=''
	{
		IFS= read -r status || :
		IFS= read -r repo || :
		IFS= read -r worktree || :
	} <<EOF
${fields}
EOF
	shown_worktree=$(printable "${worktree}")
}

# Refuses a seat that has no worktree yet or whose developer is busy.
check_status() {
	case ${status} in
		chosen) die 5 "seat ${shown_seat} is chosen: its worktree is not made yet; expected a seat with a worktree" ;;
		working) die 5 "seat ${shown_seat} is working: its developer is busy; expected it idle, open or gave-up" ;;
		*) ;;
	esac
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
	set -- --effort "${effort}" --seat "${seat}" --base "${to_sha}" --from-head "${old_head}"
	[ -z "${follows}" ] || set -- "$@" --follows "${follows}"
	run_step seats.sh move "$@"
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

# Prints the seat and the line for the human.
print_result() {
	run_step seats.sh get --effort "${effort}" --seat "${seat}"
	[ "${step_rc}" -eq 0 ] ||
		die 4 "seats.sh get failed (exit ${step_rc}; its stderr is above) after the seat was moved: the seat is moved; expected its JSON line; run sh seats.sh get --effort ${shown_effort} --seat ${shown_seat}"
	printf '%s\n' "${step_out}"
	jq -nr -L "${view_dir}" --arg seat "${seat}" --arg sha "${to_sha}" --arg follows "${follows}" \
		--argjson short_length "${SHORT_SHA_LENGTH}" '
		include "view";
		include "title";
		$sha[:$short_length] as $short
		| status_line("done"; "\($seat | seat_display) moved"; if $follows != "" then "\($follows) (\($short))" else $short end)' </dev/null ||
		die 4 "jq could not print the line; expected jq 1.6+ and ${VIEW_LIB}'s view.jq and title.jq"
}

parse_args "$@"
load_dependencies
check_inputs
read_seat
check_status
resolve_target
check_follows
name_keep_ref
move_worktree
record_move
print_result
