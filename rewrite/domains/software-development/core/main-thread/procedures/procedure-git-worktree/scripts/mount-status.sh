#!/usr/bin/env sh
# Says whether the main checkout holds a mount.sh mount and how it stands:
# whether the seat moved on since, whether HEAD moved, and which mounted
# paths the human changed. It reads only.
set -eu
umask 077

readonly PROG='mount-status.sh'
# The C locale keeps the shell, sed and awk byte-wise.
LC_ALL=C
export LC_ALL
# No git command here may refresh or write the checkout's index.
GIT_OPTIONAL_LOCKS=0
GIT_TERMINAL_PROMPT=0
export GIT_OPTIONAL_LOCKS GIT_TERMINAL_PROMPT
# An inherited repository override would make git read outside --repo.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
	GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_PREFIX

usage() {
	cat <<EOF
usage: sh ${PROG} --repo DIR
       sh ${PROG} --help | -h

Prints the state of the mount recorded in the checkout's git folder
(crucible/mount.json). Reads only; nothing is left behind (a SIGKILL
aside).

--repo DIR  absolute path of the main checkout's top folder

stdout, one JSON line:
  {"mounted":false}   nothing is mounted
  {"mounted":true,"effort":<dir>,"slot":S,"seat_commit":<sha>,
   "seat_head":<sha or null>,"stale":bool,"head_moved":bool,
   "finished":bool,"paths":[<path>...],"edited":[<path>...]}
  seat_head is the seat worktree's HEAD now, null when the worktree is
  gone; stale: seat_head is not seat_commit (false when null);
  head_moved: HEAD is not the HEAD at mount time; finished: head_moved
  and every mounted path holds what HEAD's tree holds (the human committed
  it; unmount.sh then only forgets the record); edited: the mounted paths
  that no longer hold what the mount left there

exit codes:
  0  printed
  2  wrong command line: a missing, repeated or unknown option, or a
     missing value
  3  input: --repo is not a main checkout's top folder, or the record is
     unreadable or not version 1
  4  environment: git or jq missing or failed

needs: POSIX sh, git 2.26+, jq 1.6+; mount-state.sh beside this script
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

parse_args() {
	repo=''
	while [ "$#" -gt 0 ]; do
		case $1 in
			-h | --help)
				usage
				exit 0
				;;
			--repo)
				[ -n "${2-}" ] || usage_error '--repo needs a value; expected --repo DIR'
				[ -z "${repo}" ] || usage_error '--repo given twice; expected one'
				repo=$2
				shift 2
				;;
			*)
				shown_option=$(printable "$1")
				usage_error "unknown option: ${shown_option}; expected --repo or --help"
				;;
		esac
	done
	[ -n "${repo}" ] || usage_error '--repo missing; expected --repo DIR'
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
	[ -f "${own_dir}/mount-state.sh" ] ||
		die 4 'mount-state.sh not found beside this script; expected the procedure'\''s scripts in one folder'
	# shellcheck source=mount-state.sh
	. "${own_dir}/mount-state.sh"
}

# Sets seat_head to the seat worktree's HEAD, empty when the worktree is gone.
read_seat_head() {
	seat_head=''
	[ -d "${rec_worktree}" ] || return 0
	seat_head=$(git -C "${rec_worktree}" -c core.fsmonitor=false rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null) || seat_head=''
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
locate_checkout "${repo}"
[ -z "${checkout_problem}" ] || die 3 "--repo ${checkout_problem}"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/crucible-mount-status.XXXXXX") ||
	die 4 'mktemp could not create a work folder; expected a writable TMPDIR'
read_record
if [ "${record_present}" != true ]; then
	printf '{"mounted":false}\n'
	exit 0
fi
read_seat_head
head=$(git -C "${checkout_dir}" -c core.fsmonitor=false rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null) || head=''
checkout_states "${work_dir}/spec" "${work_dir}/now-states"
check_finished "${work_dir}/now-states" "${head}"
list_mismatches "${work_dir}/spec" "${work_dir}/now-states" 2 'recreated' "${work_dir}/edited"
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
jq -nc --arg effort "${rec_effort}" --arg slot "${rec_slot}" --arg seat_commit "${rec_seat_commit}" \
	--arg seat_head "${seat_head}" --arg head "${head}" --arg rec_head "${rec_head}" --argjson finished "${finished}" \
	--rawfile spec "${work_dir}/spec" --rawfile edited "${work_dir}/edited" '
	def lines: rtrimstr("\n") | if . == "" then [] else split("\n") end;
	def path_of: split("\t") | .[2:] | join("\t");
	{mounted: true, effort: $effort, slot: $slot, seat_commit: $seat_commit,
	 seat_head: (if $seat_head == "" then null else $seat_head end),
	 stale: ($seat_head != "" and $seat_head != $seat_commit),
	 head_moved: ($head != $rec_head), finished: $finished,
	 paths: ($spec | lines | map(path_of)),
	 edited: ($edited | lines | map(split("\t") | .[1:] | join("\t")))}' ||
	die 4 'jq could not print the mount state'
