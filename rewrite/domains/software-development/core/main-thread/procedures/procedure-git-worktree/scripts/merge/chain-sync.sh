#!/usr/bin/env sh
# Brings an idle developer seat up to date with the seats it was cut from:
# when chain.sh says one of them moved on, the seat's HEAD and every moved
# seat's HEAD are merged by tips-merge.sh, and the seat's clean worktree is
# checked out at the merge. A conflict writes no file, index or ref.
set -eu
# The checkout writes the seat's files under the caller's own umask.
inherited_umask=$(umask)
umask 077

readonly PROG='chain-sync.sh'
readonly tab='	'
readonly EFFORT_TRAILER='Effort'
readonly SYNCED_TRAILER='Synced-From'
readonly AUTHOR_DOMAIN='crucible.invalid'
readonly VIEW_LIB='human-view'
# The C locale keeps the shell byte-wise.
LC_ALL=C
export LC_ALL
GIT_OPTIONAL_LOCKS=0
GIT_TERMINAL_PROMPT=0
export GIT_OPTIONAL_LOCKS GIT_TERMINAL_PROMPT
# An inherited repository override would make git act outside the seat's
# worktree.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
	GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_PREFIX

usage() {
	cat <<EOF
usage: sh ${PROG} --effort DIR --seat S
       sh ${PROG} --help | -h

Runs chain.sh for seat S; when a seat S was cut from moved on (at any
level), merges S's HEAD with every moved seat's HEAD (tips-merge.sh,
author S <S@${AUTHOR_DOMAIN}>, message "crucible(sync): S takes P <short
sha>, ...", trailers ${EFFORT_TRAILER} (seats.json's effort) and ${SYNCED_TRAILER},
no Agent-Seat, so iteration.sh does not count it) and checks S's
worktree out, detached, at the merge, with no hook run.

--effort DIR  absolute path of the effort folder (it holds seats.json)
--seat S      a developer seat, status idle (not chosen), whose worktree
              holds no uncommitted change

stdout, one JSON line:
  {"synced":false,"seat":S,"reason":"in_sync","line":null}   nothing moved
  {"synced":true,"seat":S,"commit":<sha>,"parents":[P...],"message":M,
   "line":L}
  L, for the human, each seat by its name for the human: "Software
  developer Beta now holds the latest work of Software developer Alpha
  + ..."
  M is the line to send S's developer: "Your seat S now also holds the
  latest work of P (merged at <short sha>); build on top of it.", or,
  when S had nothing of its own and takes P's HEAD as it is, "Your seat S
  now holds the latest work of P as it is (<short sha>); build on top of
  it."

exit codes:
  0  synced, or nothing to sync
  2  wrong command line: a missing, repeated or unknown option, or a
     missing value
  3  input: a bad option value, seats.json or a seat does not fit
     (seats.sh's or a neighbour's own lines first)
  4  environment: git, jq, ${VIEW_LIB} or a neighbour missing or failed, or
     the worktree is not clean at the merge after the checkout
  5  refused by state, no file, index or ref written: S is not an idle
     developer (a chosen seat has no worktree yet) or is dirty, a moved
     seat is not idle, or the HEADs conflict (tips-merge.sh's line)

needs: POSIX sh, git 2.38+, jq 1.6+; chain.sh, tips-merge.sh and
../seats/seats.sh from this script's folder; ${VIEW_LIB}'s title.jq in
${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/skills/${VIEW_LIB}
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
	effort='' seat=''
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
			*)
				shown_option=$(printable "$1")
				usage_error "unknown option: ${shown_option}; expected --effort, --seat or --help"
				;;
		esac
		shift 2
	done
	[ -n "${effort}" ] || usage_error '--effort missing; expected --effort DIR'
	[ -n "${seat}" ] || usage_error '--seat missing; expected --seat S'
}

script_dir() {
	case $0 in
		*/*) printf '%s' "${0%/*}" ;;
		*) printf '.' ;;
	esac
}

load_dependencies() {
	command -v git >/dev/null 2>&1 || die 4 'git not found; expected git 2.38+ on PATH'
	command -v jq >/dev/null 2>&1 || die 4 'jq not found; expected jq 1.6+ on PATH'
	own_path=$(script_dir)
	own_dir=$(cd -P -- "${own_path}" && pwd -P) || die 4 "this script's folder could not be entered"
	for neighbour in chain.sh tips-merge.sh ../seats/seats.sh; do
		[ -f "${own_dir}/${neighbour}" ] || {
			shown_neighbour=$(printable "${own_dir}/${neighbour}")
			die 4 "${shown_neighbour} not found; expected the procedure's scripts folders whole"
		}
	done
	view_dir="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/skills/${VIEW_LIB}"
	[ -f "${view_dir}/title.jq" ] || {
		shown_view_dir=$(printable "${view_dir}")
		die 4 "title.jq not found in ${shown_view_dir}; expected the ${VIEW_LIB} skill installed"
	}
}

# Sets effort_dir (physical) and seats_file.
check_effort() {
	shown_effort=$(printable "${effort}")
	case ${effort} in
		/*) ;;
		*) die 3 "--effort ${shown_effort} is not absolute; expected an absolute path" ;;
	esac
	effort_dir=$(cd -P -- "${effort}" 2>/dev/null && pwd -P) ||
		die 3 "--effort ${shown_effort} is not a folder; expected the effort folder"
	seats_file="${effort_dir}/seats.json"
	shown_seats=$(printable "${seats_file}")
}

# Sets role, status and worktree of seat $1 from seats.sh get; seats.sh's
# own lines say why it refused.
read_seat() {
	seat_rc=0
	seat_json=$(sh "${own_dir}/../seats/seats.sh" get --seats "${seats_file}" --seat "$1") || seat_rc=$?
	shown_seat=$(printable "$1")
	case ${seat_rc} in
		0) ;;
		2 | 3 | 6) die 3 "seats.sh get refused seat ${shown_seat} (exit ${seat_rc}); expected a seat in --effort's seats.json" ;;
		*) die 4 "seats.sh get failed (exit ${seat_rc})" ;;
	esac
	fields=$(printf '%s\n' "${seat_json}" | jq -r '.role // "", .status // "", .worktree // ""') ||
		die 4 'jq could not read the seat seats.sh get printed'
	role='' status='' worktree=''
	{
		IFS= read -r role || :
		IFS= read -r status || :
		IFS= read -r worktree || :
	} <<EOF
${fields}
EOF
}

refuse() {
	warn "$1"
	problems=$((problems + 1))
}

# Refuses a seat that is no idle developer with a clean worktree; sets
# seat_worktree.
check_seat() {
	read_seat "${seat}"
	[ "${role}" = developer ] || die 5 "seat ${shown_seat} is a ${role} seat; expected a developer seat"
	[ "${status}" != chosen ] || die 5 "seat ${shown_seat} is chosen: its worktree is not made yet; expected status idle"
	seat_worktree=${worktree}
	shown_worktree=$(printable "${seat_worktree}")
	[ -d "${seat_worktree}" ] || die 3 "seat ${shown_seat}'s worktree ${shown_worktree} is not a folder; expected its git worktree"
	check_idle
	git -C "${seat_worktree}" -c core.fsmonitor=false status --porcelain=v1 -z --untracked-files=all \
		>"${work_dir}/seat-status" 2>"${work_dir}/stderr" || git_failed "git status in the seat's worktree"
	[ ! -s "${work_dir}/seat-status" ] ||
		refuse "seat ${shown_seat}'s worktree ${shown_worktree} has uncommitted changes; expected a clean worktree"
}

# Refuses the seat read_seat read last when it is not idle.
check_idle() {
	case ${status} in
		idle) ;;
		working) refuse "seat ${shown_seat} is working: its developer is busy; expected status idle" ;;
		*) refuse "seat ${shown_seat} is ${status}; expected status idle" ;;
	esac
}

# Sets chain to chain.sh's JSON line and moved to its moved.
run_chain() {
	run_step chain.sh --effort "${effort_dir}" --seat "${seat}"
	[ "${step_rc}" -eq 0 ] || step_failed chain.sh
	chain=${step_out}
	moved=$(printf '%s\n' "${chain}" | jq -r '.moved') || die 4 'jq could not read what chain.sh printed'
}

# Writes work_dir/moved, "<seat><TAB><head>" per seat that moved on; each
# must be idle.
check_moved() {
	printf '%s\n' "${chain}" | jq -r '.parents[] | select(.in_seat | not) | "\(.seat)\t\(.head)"' \
		>"${work_dir}/moved" 2>/dev/null || die 4 'jq could not read what chain.sh printed'
	while IFS= read -r moved_line; do
		read_seat "${moved_line%%"${tab}"*}"
		check_idle
	done <"${work_dir}/moved"
}

# Sets effort_id from seats.json's effort, the value of the seats' Effort
# trailer.
read_effort_id() {
	effort_id=$(jq -r '.effort | strings' "${seats_file}" 2>/dev/null) ||
		die 3 "${shown_seats} is not JSON; expected the effort's seats.json"
	[ -n "${effort_id}" ] || die 3 "${shown_seats} has no effort; expected a non-empty effort string"
}

# Merges the seat's HEAD with every moved seat's HEAD; sets merge_commit.
merge_moved() {
	seat_head=$(printf '%s\n' "${chain}" | jq -r '.head') || die 4 'jq could not read what chain.sh printed'
	takes='' synced_from=''
	set -- --repo "${seat_worktree}" --commit "${seat_head}"
	while IFS= read -r moved_line; do
		moved_head=${moved_line#*"${tab}"}
		short_sha "${moved_head}"
		takes="${takes:+${takes}, }${moved_line%%"${tab}"*} ${short}"
		synced_from="${synced_from:+${synced_from}, }${moved_line%%"${tab}"*}"
		set -- "$@" --commit "${moved_head}"
	done <"${work_dir}/moved"
	merge_message="${work_dir}/sync-message"
	printf 'crucible(sync): %s takes %s\n\n%s: %s\n%s: %s\n' "${seat}" "${takes}" \
		"${EFFORT_TRAILER}" "${effort_id}" "${SYNCED_TRAILER}" "${synced_from}" >"${merge_message}" ||
		die 4 'could not write the merge message in the work folder'
	run_step tips-merge.sh "$@" --message-file "${merge_message}" --author-name "${seat}" --author-email "${seat}@${AUTHOR_DOMAIN}"
	case ${step_rc} in
		0) ;;
		5) exit 5 ;;
		*) step_failed tips-merge.sh ;;
	esac
	merge_commit=$(printf '%s\n' "${step_out}" | jq -r '.commit') || die 4 'jq could not read what tips-merge.sh printed'
	merge_new=$(printf '%s\n' "${step_out}" | jq -r '.new') || die 4 'jq could not read what tips-merge.sh printed'
}

# Sets short to the abbreviated sha of commit $1.
short_sha() {
	short=$(git -C "${seat_worktree}" -c core.fsmonitor=false rev-parse --short "$1" 2>"${work_dir}/stderr") ||
		git_failed 'git rev-parse --short'
}

# Checks the seat's worktree out at the merge, then proves HEAD is the merge
# and the worktree clean.
check_out_merge() {
	(umask "${inherited_umask}" && exec git -C "${seat_worktree}" -c core.hooksPath=/dev/null -c core.fsmonitor=false \
		checkout --detach --quiet "${merge_commit}") 2>"${work_dir}/stderr" ||
		git_failed "git checkout of the merge in the seat's worktree"
	now_head=$(git -C "${seat_worktree}" -c core.fsmonitor=false rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null) || now_head=''
	[ "${now_head}" = "${merge_commit}" ] ||
		die 4 "seat ${seat}'s worktree HEAD is ${now_head:-none} after the checkout, not the merge ${merge_commit}"
	git -C "${seat_worktree}" -c core.fsmonitor=false status --porcelain=v1 -z --untracked-files=all \
		>"${work_dir}/seat-status" 2>"${work_dir}/stderr" || git_failed "git status in the seat's worktree"
	[ ! -s "${work_dir}/seat-status" ] ||
		die 4 "seat ${seat}'s worktree is not clean after the checkout of the merge ${merge_commit}"
}

# Runs neighbour $1, a path from this script's folder, with the rest as
# arguments; its stdout in step_out, its exit code in step_rc; its stderr
# passes through.
run_step() {
	step_rc=0
	step_script=$1
	shift
	step_out=$(sh "${own_dir}/${step_script}" "$@") || step_rc=$?
}

# Exits naming failed neighbour $1: 3 when it refused its input, else 4.
step_failed() {
	case ${step_rc} in
		3) die 3 "$1 refused its input (exit 3); expected seat ${seat} and its chain to fit" ;;
		*) die 4 "$1 failed (exit ${step_rc})" ;;
	esac
}

# Exits 4 naming step $1 and the first line of work_dir/stderr.
git_failed() {
	first_line=$(head -n 1 "${work_dir}/stderr" 2>/dev/null) || first_line=''
	shown_line=$(printable "${first_line}")
	die 4 "$1 failed: ${shown_line}"
}

# shellcheck disable=SC2329 # invoked by the EXIT trap
clean_up() {
	[ -z "${work_dir}" ] || rm -rf -- "${work_dir}"
}

work_dir=''
trap clean_up EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

parse_args "$@"
load_dependencies
check_effort
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/crucible-chain-sync.XXXXXX") ||
	die 4 'mktemp could not create a work folder; expected a writable TMPDIR'
# tips-merge.sh takes only an absolute message file.
physical_work_dir=$(cd -P -- "${work_dir}" && pwd -P) || die 4 'the work folder could not be entered'
work_dir=${physical_work_dir}

problems=0
check_seat
[ "${problems}" -eq 0 ] || exit 5
run_chain
if [ "${moved}" != true ]; then
	jq -nc --arg seat "${seat}" '{synced: false, seat: $seat, reason: "in_sync", line: null}' || die 4 'jq could not print the result'
	exit 0
fi
check_moved
[ "${problems}" -eq 0 ] || exit 5
read_effort_id
merge_moved
check_out_merge
short_sha "${merge_commit}"
jq -nc -L "${view_dir}" --arg seat "${seat}" --arg commit "${merge_commit}" --arg synced_from "${synced_from}" --arg short "${short}" \
	--argjson new "${merge_new}" \
	'include "title";
	($synced_from | split(", ")) as $parents | ($parents | join(", ")) as $named
	| {synced: true, seat: $seat, commit: $commit, parents: $parents,
	   message: (if $new then "Your seat \($seat) now also holds the latest work of \($named) (merged at \($short)); build on top of it."
		else "Your seat \($seat) now holds the latest work of \($named) as it is (\($short)); build on top of it." end),
	   line: "\($seat | seat_display) now holds the latest work of \($parents | map(seat_display) | join(" + "))."}' ||
	die 4 "jq could not print the result; expected jq 1.6+ and ${VIEW_LIB}'s title.jq"
