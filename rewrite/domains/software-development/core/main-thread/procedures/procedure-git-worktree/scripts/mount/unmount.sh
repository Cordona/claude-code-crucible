#!/usr/bin/env sh
# Takes a mount.sh mount out of the main checkout again: the saved patch is
# reversed in the working tree only, and only while HEAD and every mounted
# path are exactly as mount.sh left them, so nothing the human did since is
# lost. Then the record goes.
set -eu
# git apply writes the checkout's files under the human's own umask.
inherited_umask=$(umask)
umask 077

readonly PROG='unmount.sh'
# The C locale keeps the shell, sed and awk byte-wise.
LC_ALL=C
export LC_ALL
# No git command here may refresh or write the checkout's index.
GIT_OPTIONAL_LOCKS=0
GIT_TERMINAL_PROMPT=0
export GIT_OPTIONAL_LOCKS GIT_TERMINAL_PROMPT
# An inherited repository override would make git act outside --repo.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
	GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_PREFIX

usage() {
	cat <<EOF
usage: sh ${PROG} --repo DIR
       sh ${PROG} --help | -h

Reverses the mount recorded in the checkout's git folder
(crucible/mount.json, crucible/mount.patch) in the working tree, puts back
the exact bytes and mode of each file the mount replaced from the record's
raw copies (crucible/before/), then removes the record and the folders the mount created that are empty again.
When the mount is finished (HEAD moved since the mount and every mounted
path holds what HEAD's tree holds: the human committed it), only the record
is removed and no file is touched. Never touches the index, a ref or a path
outside the record. Refused, with nothing touched, when HEAD moved but the
mount is not finished, or a mounted path no longer holds what the mount
left there.

--repo DIR  absolute path of the main checkout's top folder

A record of version 1 (one seat) or 2 (one or more seats) is read.

stdout, one JSON line:
  {"unmounted":true,"slots":[S...],"paths":N,"line":L}           reversed
  {"unmounted":false,"forgotten":true,"slots":[S...],"line":L}   finished:
                                                       record removed
  L, for the human: "Unmounted S + S from <repo>." or "S + S are committed
  in <repo>; the mount record is dropped." (control characters as "?")

exit codes:
  0  unmounted, or a finished mount forgotten
  2  wrong command line: a missing, repeated or unknown option, or a
     missing value
  3  input: --repo is not a main checkout's top folder, or the record is
     unreadable or not version 1 or 2
  4  environment: git or jq missing or failed, a write failed, or the
     reversed paths or their bytes did not verify (the record is kept)
  5  refused by state: nothing mounted, HEAD moved with mounted paths
     still uncommitted, a mounted path changed, or git apply -R --check
     failed; nothing touched

needs: POSIX sh, git 2.26+, jq 1.6+; mount-lib.sh beside this script
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
	[ -f "${own_dir}/mount-lib.sh" ] || {
		shown_neighbour=$(printable "${own_dir}/mount-lib.sh")
		die 4 "${shown_neighbour} not found; expected the procedure's scripts folders whole"
	}
	# shellcheck source=mount-lib.sh
	. "${own_dir}/mount-lib.sh"
}

refuse() {
	warn "$1"
	problems=$((problems + 1))
}

# Refuses a HEAD that moved without the mounted paths being committed,
# listing the paths still uncommitted.
check_head() {
	refuse "HEAD moved since the mount (already committed?); nothing touched: HEAD is ${head:-none}, the mount was on ${rec_head}; to forget the mount, delete ${shown_record_dir}"
	warn_mismatches "${work_dir}/uncommitted" 'still uncommitted: ' ''
}

check_paths_as_mounted() {
	list_mismatches "${work_dir}/spec" "${work_dir}/now-states" 2 'recreated' "${work_dir}/edited"
	[ -s "${work_dir}/edited" ] || return 0
	problems=$((problems + 1))
	warn_mismatches "${work_dir}/edited" 'changed since the mount: ' ''
	warn 'nothing was touched: undo your edits, then run unmount.sh again; or commit the mounted paths, and the mount counts as finished'
}

check_reverse() {
	git -C "${checkout_dir}" -c core.fsmonitor=false apply -R --check --binary --whitespace=nowarn -- "${record_dir}/mount.patch" \
		>/dev/null 2>"${work_dir}/stderr" || {
		refuse 'git apply -R --check refused the saved patch; nothing touched:'
		while IFS= read -r apply_line; do
			shown_line=$(printable "${apply_line}")
			warn "  ${shown_line}"
		done <"${work_dir}/stderr"
	}
}

reverse_patch() {
	(umask "${inherited_umask}" && exec git -C "${checkout_dir}" -c core.fsmonitor=false apply -R --binary --whitespace=nowarn \
		-- "${record_dir}/mount.patch") 2>"${work_dir}/stderr" ||
		git_failed 'git apply -R in the main checkout (the record is kept)'
	checkout_states "${work_dir}/spec" "${work_dir}/after-states"
	list_mismatches "${work_dir}/spec" "${work_dir}/after-states" 1 'present where the checkout had none' "${work_dir}/unverified"
	[ -s "${work_dir}/unverified" ] || return 0
	warn_mismatches "${work_dir}/unverified" 'after reversing, the main checkout differs from before the mount at ' ''
	die 4 "the reversed paths did not verify; the record in ${shown_record_dir} is kept"
}

# Removes each now-empty folder above a path the mount added, deepest
# first; rmdir leaves any folder that still holds something.
remove_empty_folders() {
	while IFS= read -r spec_line; do
		[ "${spec_line%%"${tab}"*}" = absent ] || continue
		added_path=${spec_line#*"${tab}"}
		added_path=${added_path#*"${tab}"}
		while :; do
			case ${added_path} in
				*/*) added_path=${added_path%/*} ;;
				*) break ;;
			esac
			[ -d "${checkout_dir}/${added_path}" ] && [ ! -L "${checkout_dir}/${added_path}" ] || continue
			rmdir -- "${checkout_dir}/${added_path}" 2>/dev/null || break
		done
	done <"${work_dir}/spec"
}

# shellcheck disable=SC2329 # invoked by the EXIT trap
clean_up() {
	[ -z "${restore_temp}" ] || rm -f -- "${restore_temp}"
	[ -z "${work_dir}" ] || rm -rf -- "${work_dir}"
}

work_dir='' restore_temp=''
trap clean_up EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

parse_args "$@"
load_dependencies
locate_checkout "${repo}"
[ -z "${checkout_problem}" ] || die 3 "--repo ${checkout_problem}"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/crucible-unmount.XXXXXX") ||
	die 4 'mktemp could not create a work folder; expected a writable TMPDIR'
read_record
shown_record_dir=$(printable "${record_dir}")
[ "${record_present}" = true ] || die 5 "nothing is mounted in ${shown_checkout}: no record in ${shown_record_dir}"
[ -f "${record_dir}/mount.patch" ] || die 3 "the record in ${shown_record_dir} has no mount.patch; expected mount.sh's record"

head=$(git -C "${checkout_dir}" -c core.fsmonitor=false rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null) || head=''
checkout_states "${work_dir}/spec" "${work_dir}/now-states"
check_finished "${work_dir}/now-states" "${head}"
if [ "${finished}" = true ]; then
	remove_record
	# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
	jq -nc --arg slots "${rec_slots}" --arg repo "${checkout_dir}" '{unmounted: false, forgotten: true, slots: ($slots | split(" "))}
		| .line = "\(.slots | join(" + ")) are committed in \($repo | gsub("[\u0000-\u001f\u007f]"; "?")); the mount record is dropped."' ||
		die 4 'jq could not print the result; the record is removed'
	exit 0
fi
# A finished mount needs no saved copy; a reversal needs every one.
list_saved
while IFS= read -r saved_line; do
	[ -f "${record_dir}/before/${saved_line%%"${tab}"*}" ] ||
		die 3 "the record in ${shown_record_dir} lacks the saved copy before/${saved_line%%"${tab}"*}; expected mount.sh's record"
done <"${work_dir}/saved"
problems=0
if [ "${head}" != "${rec_head}" ]; then
	check_head
else
	check_paths_as_mounted
fi
[ "${problems}" -ne 0 ] || check_reverse
[ "${problems}" -eq 0 ] || exit 5

reverse_patch
restore_saved_bytes "the record in ${shown_record_dir} is kept"
remove_empty_folders
remove_record
paths=$(wc -l <"${work_dir}/spec" | tr -d ' ') || die 4 'wc failed counting the unmounted paths'
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
jq -nc --arg slots "${rec_slots}" --argjson paths "${paths}" --arg repo "${checkout_dir}" \
	'{unmounted: true, slots: ($slots | split(" ")), paths: $paths}
	| .line = "Unmounted \(.slots | join(" + ")) from \($repo | gsub("[\u0000-\u001f\u007f]"; "?"))."' ||
	die 4 'jq could not print the result; the mount is removed'
