#!/usr/bin/env sh
# Commits a seat's freshly written dispatch file, alone, on the seat's
# worktree before its agent launches, so the history shows what each agent
# was given. It checks the seat and the path, reads the effort's identity
# with procedure-git-setup's settings.sh, then only runs commit-message.sh
# and commit.sh.
set -eu
umask 077

readonly PROG='seed-commit.sh'
readonly SEATS_DIR='.crucible/seats'
# From this folder to the effort settings' reader.
readonly SETTINGS='../../../procedure-git-setup/scripts/settings.sh'
# The C locale keeps the shell byte-wise; jq writes the JSON as UTF-8.
LC_ALL=C
export LC_ALL
GIT_TERMINAL_PROMPT=0
export GIT_TERMINAL_PROMPT
# An inherited repository override would make git read outside the worktree.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
	GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_PREFIX

usage() {
	cat <<EOF
usage: sh ${PROG} --seats FILE --seat S --dispatch FILE
       sh ${PROG} --help | -h

Commits exactly --dispatch, and nothing else, on seat S's worktree, through
commit-message.sh and commit.sh: author and committer the identity that
settings.sh get --effort <the folder of --seats> prints, signed with its key
when it has one (commit.sh's UNSIGNED: line passes through), the message

  crucible(dispatch): seat <S>[, handover]

  Effort: <seats.json's effort>
  Agent-Seat: <S>
  Dispatch: <ID>

", handover" when S's previous_agent_ids in seats.json is not empty.

--seats FILE     absolute path of the effort's seats.json
--seat S         a seat with a worktree (seats.json's worktree)
--dispatch FILE  absolute path of S's dispatch file, named dispatch-<ID>.json,
                 directly in <worktree>/${SEATS_DIR}/<S>/ (symlinks
                 resolved), not a link, not yet in the worktree's HEAD;
                 committed even where a repo ignore rule covers it

stdout: SEED: <the new commit's full sha>, on exit 0 and 5

exit codes:
  0  committed
  2  wrong command line: a missing, repeated or unknown option, or a
     missing value
  3  input: no such seat, no worktree, the path outside the seat folder,
     the file missing or already committed, no git setup for the effort,
     or settings.sh, commit-message.sh or commit.sh refused its input
     (their own stderr lines first)
  4  environment: git or jq missing, or seats.sh, settings.sh,
     commit-message.sh or commit.sh missing or failed otherwise, a commit.sh exit 7 with the
     worktree's HEAD unmoved included; nothing was committed
  5  commit.sh made a commit it could not verify (its exit 7, HEAD moved):
     the commit stays, SEED names the worktree's HEAD and stderr says so

needs: POSIX sh, git 2.26+, jq 1.6+; ../seats/seats.sh, commit-message.sh
and commit.sh from this script's folder; procedure-git-setup's settings.sh
beside procedure-git-worktree
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
	seats_file='' seat='' dispatch_file=''
	while [ "$#" -gt 0 ]; do
		case $1 in
			-h | --help)
				usage
				exit 0
				;;
			--seats)
				take_value "$1" "${seats_file}" "${2-}" FILE
				seats_file=${option_value}
				;;
			--seat)
				take_value "$1" "${seat}" "${2-}" S
				seat=${option_value}
				;;
			--dispatch)
				take_value "$1" "${dispatch_file}" "${2-}" FILE
				dispatch_file=${option_value}
				;;
			*)
				shown_option=$(printable "$1")
				usage_error "unknown option: ${shown_option}; expected --seats, --seat, --dispatch or --help"
				;;
		esac
		shift 2
	done
	[ -n "${seats_file}" ] || usage_error '--seats missing; expected --seats FILE'
	[ -n "${seat}" ] || usage_error '--seat missing; expected --seat S'
	[ -n "${dispatch_file}" ] || usage_error '--dispatch missing; expected --dispatch FILE'
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
	for neighbour in ../seats/seats.sh commit-message.sh commit.sh "${SETTINGS}"; do
		[ -f "${own_dir}/${neighbour}" ] || {
			shown_neighbour=$(printable "${own_dir}/${neighbour}")
			die 4 "${shown_neighbour} not found; expected the procedure's scripts folders whole"
		}
	done
}

# Sets effort, worktree and handover from seats.json and the seat;
# seats.sh's own lines say why it refused.
read_seat() {
	shown_seat=$(printable "${seat}")
	seat_rc=0
	seat_json=$(sh "${own_dir}/../seats/seats.sh" get --seats "${seats_file}" --seat "${seat}") || seat_rc=$?
	case ${seat_rc} in
		0) ;;
		2 | 3 | 6) die 3 "seats.sh get refused seat ${shown_seat} (exit ${seat_rc}); expected a seat in --seats" ;;
		*) die 4 "seats.sh get failed (exit ${seat_rc})" ;;
	esac
	effort=$(jq -r '.effort | strings' "${seats_file}" 2>/dev/null) || die 4 'jq could not read the effort from --seats'
	[ -n "${effort}" ] || die 3 '--seats has no effort; expected a non-empty effort string'
	fields=$(printf '%s\n' "${seat_json}" |
		jq -r '.worktree // "", (if (.previous_agent_ids // []) == [] then "no" else "yes" end)') ||
		die 4 'jq could not read the seat seats.sh get printed'
	worktree='' handover=''
	{
		IFS= read -r worktree || :
		IFS= read -r handover || :
	} <<EOF
${fields}
EOF
	[ -n "${worktree}" ] || die 3 "seat ${shown_seat} has no worktree; expected a writer seat with one"
	shown_worktree=$(printable "${worktree}")
	real_worktree=$(cd -P -- "${worktree}" 2>/dev/null && pwd -P) ||
		die 3 "seat ${shown_seat}'s worktree ${shown_worktree} is not a folder; expected the seat opened"
}

# Sets the identity_* variables from settings.sh get for the effort folder
# holding --seats; its own lines say why it refused.
read_identity() {
	effort_dir=$(cd -P -- "${seats_file%/*}" 2>/dev/null && pwd -P) ||
		die 3 '--seats is not in a folder that can be entered; expected the effort folder'
	step_rc=0
	settings=$(sh "${own_dir}/${SETTINGS}" get --effort "${effort_dir}") || step_rc=$?
	case ${step_rc} in
		0) ;;
		3 | 5) die 3 "settings.sh get refused the effort (exit ${step_rc}); expected its git setup; nothing was committed" ;;
		*) die 4 "settings.sh get failed (exit ${step_rc}); nothing was committed" ;;
	esac
	identity_name='' identity_email='' signing_format='' signing_key=''
	while IFS= read -r setting; do
		case ${setting} in
			NAME=*) identity_name=${setting#NAME=} ;;
			EMAIL=*) identity_email=${setting#EMAIL=} ;;
			SIGNING_FORMAT=*) signing_format=${setting#SIGNING_FORMAT=} ;;
			SIGNING_KEY=*) signing_key=${setting#SIGNING_KEY=} ;;
			*) ;;
		esac
	done <<EOF
${settings}
EOF
	[ -n "${identity_name}" ] && [ -n "${identity_email}" ] ||
		die 4 'settings.sh get printed no NAME or EMAIL line; expected both'
}

# Sets dispatch_id and relative_path, refusing a file that is not S's own,
# missing, or already committed.
check_dispatch() {
	shown_dispatch=$(printable "${dispatch_file}")
	expected="expected ${shown_worktree}/${SEATS_DIR}/${shown_seat}/dispatch-<ID>.json"
	case ${dispatch_file} in
		*[[:cntrl:]]*) die 3 "--dispatch ${shown_dispatch} holds a control character; ${expected}" ;;
		/*/dispatch-?*.json) ;;
		*) die 3 "--dispatch ${shown_dispatch} is not an absolute dispatch-<ID>.json path; ${expected}" ;;
	esac
	file_name=${dispatch_file##*/}
	dispatch_id=${file_name#dispatch-}
	dispatch_id=${dispatch_id%.json}
	case ${dispatch_id} in
		*[!A-Za-z0-9_-]*) die 3 "--dispatch ${shown_dispatch} has an id of other than letters, digits, _ and -; ${expected}" ;;
		*) ;;
	esac
	[ -f "${dispatch_file}" ] && [ ! -L "${dispatch_file}" ] || die 3 "--dispatch ${shown_dispatch} is missing or a link; ${expected}"
	real_folder=$(cd -P -- "${dispatch_file%/*}" 2>/dev/null && pwd -P) || real_folder=''
	[ "${real_folder}" = "${real_worktree}/${SEATS_DIR}/${seat}" ] ||
		die 3 "--dispatch ${shown_dispatch} is outside seat ${shown_seat}'s folder; ${expected}"
	relative_path="${SEATS_DIR}/${seat}/${file_name}"
	if git -C "${real_worktree}" -c core.fsmonitor=false cat-file -e "HEAD:${relative_path}" 2>/dev/null; then
		die 3 "--dispatch ${shown_dispatch} is already committed in the worktree's HEAD; expected a new dispatch file"
	fi
}

# Writes the message input and the message file into the work folder.
write_message() {
	jq -nc --arg seat "${seat}" --arg handover "${handover}" --arg effort "${effort}" --arg dispatch "${dispatch_id}" \
		'{kind: "dispatch", text: "seat \($seat)\(if $handover == "yes" then ", handover" else "" end)",
			trailers: {effort: $effort, "agent-seat": $seat, dispatch: $dispatch}}' >"${work_dir}/input.json" ||
		die 4 'jq could not write the message input'
	step_rc=0
	sh "${own_dir}/commit-message.sh" --input "${work_dir}/input.json" --out "${work_dir}/message" || step_rc=$?
	step_exit commit-message.sh
}

commit_dispatch() {
	printf '%s\n' "${relative_path}" >"${work_dir}/paths" || die 4 'could not write the paths file'
	head_before=$(worktree_head)
	step_rc=0
	set -- --identity-name "${identity_name}" --identity-email "${identity_email}"
	[ -z "${signing_key}" ] || set -- "$@" --signing-format "${signing_format}" --signing-key "${signing_key}"
	sha=$(sh "${own_dir}/commit.sh" --worktree "${real_worktree}" --message-file "${work_dir}/message" \
		"$@" --paths-file "${work_dir}/paths") || step_rc=$?
	[ "${step_rc}" -ne 7 ] || unverified_commit
	step_exit commit.sh
	printf 'SEED: %s\n' "${sha}"
}

# Prints the worktree's HEAD commit, or nothing when it has none.
worktree_head() {
	git -C "${real_worktree}" -c core.fsmonitor=false rev-parse --verify -q 'HEAD^{commit}' 2>/dev/null || :
}

# commit.sh's exit 7: a commit landed that it could not prove is the one
# asked for. It stays, named, for the caller to keep the file it holds. An
# unmoved HEAD holds no commit of this run, so nothing is named.
unverified_commit() {
	head_sha=$(worktree_head)
	[ -n "${head_sha}" ] && [ "${head_sha}" != "${head_before}" ] ||
		die 4 'commit.sh failed (exit 7; its stderr is above) and the worktree'\''s HEAD did not move to a new commit; nothing was committed'
	printf 'SEED: %s\n' "${head_sha}"
	die 5 "commit.sh made commit ${head_sha} but could not verify it (exit 7; its stderr is above); the commit stays"
}

# Returns after a step that succeeded; exits 3 when step $1 refused its
# input or found nothing to commit, else 4.
step_exit() {
	case ${step_rc} in
		0) return 0 ;;
		3 | 5) die 3 "$1 refused (exit ${step_rc}); nothing was committed" ;;
		*) die 4 "$1 failed (exit ${step_rc})" ;;
	esac
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
read_seat
check_dispatch
read_identity
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/crucible-seed-commit.XXXXXX") ||
	die 4 'mktemp could not create a work folder; expected a writable TMPDIR'
write_message
commit_dispatch
