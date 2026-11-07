#!/usr/bin/env sh
# Says whether the main checkout holds a mount.sh mount and how it stands:
# whether a seat moved on since, whether a seat it was cut from has work the
# mount lacks, whether HEAD moved, and which mounted paths the human changed.
# It reads only.
set -eu
umask 077

readonly PROG='mount-status.sh'
readonly VIEW_LIB='human-view'
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

A record of version 1 (one seat) or 2 (one or more seats) is read.

stdout, one JSON line:
  {"mounted":false,"line":L}   nothing is mounted
  {"mounted":true,"effort":<dir>,"seats":[{"seat":S,"seat_commit":<sha>,
   "seat_head":<sha or null>,"stale":bool}...],"stale":bool,
   "parents_moved":[{"seat":S,"parent":P}...] or null,"head_moved":bool,
   "finished":bool,"paths":[<path>...],"edited":[<path>...],"line":L}
  seat_head is the seat worktree's HEAD now, null when the worktree is
  gone; a seat is stale when seat_head is not seat_commit (false when
  null), the mount when any seat is; parents_moved: each seat P a mounted
  seat S was cut from (seats.json's base_seats, followed through every
  level) whose worktree HEAD the mount's target lacks, null (not checked)
  when seats.json or a seat can't be read; head_moved: HEAD is not the HEAD at mount time;
  finished: head_moved and every mounted path holds what HEAD's tree holds
  (the human committed it; unmount.sh then only forgets the record);
  edited: the mounted paths that no longer hold what the mount left there;
  line: one sentence of the above for the human, to relay word for word
  (each seat by its name for the human, like Software developer Alpha; at
  most 20 edited paths named; control characters as "?")

exit codes:
  0  printed
  2  wrong command line: a missing, repeated or unknown option, or a
     missing value
  3  input: --repo is not a main checkout's top folder, or the record is
     unreadable or not version 1 or 2
  4  environment: git, jq or ${VIEW_LIB} missing or failed

needs: POSIX sh, git 2.26+, jq 1.6+; mount-lib.sh, ../merge/chain.jq and
../seats/seats.jq from this script's folder; ${VIEW_LIB}'s title.jq in
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
	for neighbour in mount-lib.sh ../merge/chain.jq ../seats/seats.jq; do
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
	# shellcheck source=mount-lib.sh
	. "${own_dir}/mount-lib.sh"
}

# Writes work_dir/seat-heads, "<seat><TAB><seat commit><TAB><seat head>"
# per mounted seat; the head is empty when the worktree is gone.
read_seat_heads() {
	while IFS= read -r rec_seat; do
		seat_worktree=${rec_seat#*"${tab}"}
		seat_worktree=${seat_worktree%"${tab}"*}
		seat_head=''
		[ ! -d "${seat_worktree}" ] ||
			seat_head=$(git -C "${seat_worktree}" -c core.fsmonitor=false rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null) ||
			seat_head=''
		printf '%s\t%s\t%s\n' "${rec_seat%%"${tab}"*}" "${rec_seat##*"${tab}"}" "${seat_head}"
	done <"${work_dir}/rec-seats" >"${work_dir}/seat-heads"
}

# Writes work_dir/parents-moved, "<seat><TAB><parent>" per seat a mounted
# seat was cut from whose worktree HEAD the mount's target lacks; a
# parent without a worktree or HEAD has nothing to give. Sets
# parents_checked; any failure makes it false.
list_parents_moved() {
	: >"${work_dir}/parents-moved"
	parents_checked=false
	# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
	jq -r -L "${own_dir}/../merge" --rawfile seats "${work_dir}/rec-seats" 'include "chain";
		($seats | rtrimstr("\n") | split("\n") | map(split("\t") | .[0]))[] as $seat
		| ancestors($seat) | [$seat, .seat, .worktree] | join("\t")' "${rec_effort}/seats.json" \
		>"${work_dir}/ancestors" 2>/dev/null || return 0
	while IFS= read -r ancestor_line; do
		mounted_seat=${ancestor_line%%"${tab}"*}
		ancestor_rest=${ancestor_line#*"${tab}"}
		parent=${ancestor_rest%%"${tab}"*}
		parent_worktree=${ancestor_rest#*"${tab}"}
		[ -n "${parent_worktree}" ] && [ -d "${parent_worktree}" ] || continue
		parent_head=$(git -C "${parent_worktree}" -c core.fsmonitor=false rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null) ||
			continue
		ancestor_rc=0
		git -C "${checkout_dir}" -c core.fsmonitor=false merge-base --is-ancestor "${parent_head}" "${rec_target}" \
			>/dev/null 2>&1 || ancestor_rc=$?
		case ${ancestor_rc} in
			0) ;;
			1) printf '%s\t%s\n' "${mounted_seat}" "${parent}" >>"${work_dir}/parents-moved" ;;
			*) return 0 ;;
		esac
	done <"${work_dir}/ancestors"
	parents_checked=true
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
	# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
	jq -nc --arg repo "${checkout_dir}" \
		'{mounted: false, line: "Nothing is mounted in \($repo | gsub("[\u0000-\u001f\u007f]"; "?"))."}' ||
		die 4 'jq could not print the mount state'
	exit 0
fi
read_seat_heads
list_parents_moved
head=$(git -C "${checkout_dir}" -c core.fsmonitor=false rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null) || head=''
checkout_states "${work_dir}/spec" "${work_dir}/now-states"
check_finished "${work_dir}/now-states" "${head}"
list_mismatches "${work_dir}/spec" "${work_dir}/now-states" 2 'recreated' "${work_dir}/edited"
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
jq -nc -L "${view_dir}" --arg effort "${rec_effort}" --arg repo "${checkout_dir}" --rawfile seats "${work_dir}/seat-heads" \
	--argjson parents_checked "${parents_checked}" --argjson max "${MAX_LISTED}" \
	--rawfile parents_moved "${work_dir}/parents-moved" --arg head "${head}" --arg rec_head "${rec_head}" \
	--argjson finished "${finished}" --rawfile spec "${work_dir}/spec" --rawfile edited "${work_dir}/edited" '
	include "title";
	def lines: rtrimstr("\n") | if . == "" then [] else split("\n") end;
	def path_of: split("\t") | .[2:] | join("\t");
	def shown: gsub("[\u0000-\u001f\u007f]"; "?");
	def listed: if . == [] then "none" else join(", ") end;
	($seats | lines | map(split("\t") | {seat: .[0], seat_commit: .[1], seat_head: (if .[2] == "" then null else .[2] end)}
		| .stale = (.seat_head != null and .seat_head != .seat_commit))) as $mounted
	| {mounted: true, effort: $effort, seats: $mounted, stale: any($mounted[]; .stale),
	 parents_moved: (if $parents_checked then $parents_moved | lines | map(split("\t") | {seat: .[0], parent: .[1]}) else null end),
	 head_moved: ($head != $rec_head), finished: $finished,
	 paths: ($spec | lines | map(path_of)),
	 edited: ($edited | lines | map(split("\t") | .[1:] | join("\t")))}
	| .line = "Mounted in \($repo | shown): \(.seats | map(.seat | seat_display) | join(" + "))"
		+ "; moved on since: \(.seats | map(select(.stale) | .seat | seat_display) | listed)"
		+ "; cut-from seats with newer work: "
		+ (if .parents_moved == null then "not checked" else .parents_moved | map("\(.parent | seat_display) → \(.seat | seat_display)") | listed end)
		+ "; HEAD moved: \(if .head_moved then "yes" else "no" end)"
		+ "; edited: \(if .edited == [] then "none"
			else (.edited[:$max] | map(shown) | join(", ")) + (if (.edited | length) > $max then " and \((.edited | length) - $max) more" else "" end) end)."' ||
	die 4 'jq could not print the mount state'
