#!/usr/bin/env sh
# Makes one signed commit object from a tree and its parents; writes git
# objects only.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2310,SC2312 # gc_repo_git and the git reads in tests are one git command each: a failure gives an empty or wrong value, which the check then refuses
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh commit-object.sh --repo DIR --tree SHA --parent SHA [SHA]...
           [--parent SHA]... --message-file FILE --effort FOLDER

Run by worktree-snapshot.sh and worktree-discard.sh; not for main to call.
Writes one commit object of a tree with the given parents.
Use it for a tree you already have; commit-tree.sh commits a worktree instead.

Options:
  --repo DIR           a folder in the repository or a worktree, absolute
  --tree SHA           a revision naming a tree, not a commit or tag
  --parent SHA         a commit; repeatable, several per flag; kept in order
  --message-file FILE  the message, absolute; "Effort: <effort folder name>"
                       is added if absent; another effort's is refused
  --effort FOLDER      the effort's folder, absolute
Requires:  an identity for this repository in the effort (git-identity)
Writes:    one commit object as that identity, signed with its key; no ref,
           index, file or git config changes; no hook runs
Stdout:    one JSON line {"commit": "<sha>", "signed": true|false}; signed
           is false when signing failed or took over 10 s, stderr says why
Exit:
  0  written
  2  refused, nothing written; the reason is on stderr
  4  git failed: fix the repository from stderr's reason and rerun
USAGE
}

gc_prog='commit-object.sh'
. "$(dirname -- "$0")/../lib/git-commit.sh"

fail() {
	printf '%s: %s\n' "${gc_prog}" "$1" >&2
	exit 4
}

# Sets object to the full sha of $1 as a $2 object, refusing anything else.
resolve() {
	case $1 in -*) gc_refuse "$3 $1 is not a $2" ;; *) ;; esac
	object=$(gc_repo_git rev-parse --verify --quiet --end-of-options "$1^{$2}" 2>/dev/null) ||
		gc_refuse "$3 $1 is not a $2 in ${repo}"
}

repo='' tree='' message_file='' effort='' parent_count=0
gc_make_work
: >"${gc_work}/args"
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--repo | --tree | --message-file | --effort)
			[ $# -ge 2 ] && [ -n "$2" ] || gc_refuse "$1 needs a value"
			case $1 in --repo) repo=$2 ;; --tree) tree=$2 ;; --message-file) message_file=$2 ;; --effort) effort=$2 ;; *) ;; esac
			shift 2 ;;
		--parent)
			shift
			[ $# -ge 1 ] && [ -n "$1" ] && [ "${1#--}" = "$1" ] || gc_refuse '--parent needs a value'
			while [ $# -ge 1 ] && [ "${1#--}" = "$1" ]; do
				printf '%s\n' "$1" >>"${gc_work}/args"
				parent_count=$((parent_count + 1))
				shift
			done ;;
		*) gc_refuse "unknown argument $1; try --help" ;;
	esac
done
[ -n "${repo}" ] || gc_refuse '--repo missing'
[ -n "${tree}" ] || gc_refuse '--tree missing'
[ -n "${message_file}" ] || gc_refuse '--message-file missing'
[ -n "${effort}" ] || gc_refuse '--effort missing'
[ "${parent_count}" -ge 1 ] || gc_refuse '--parent missing; expected one or more'
command -v git >/dev/null 2>&1 || gc_refuse 'git not found'
command -v jq >/dev/null 2>&1 || gc_refuse 'jq not found'
gc_find_neighbours "$0"
gc_check_repo "${repo}"
gc_check_effort "${effort}"
resolve "${tree}" tree --tree
# A commit or tag would peel to its tree; only a tree object is taken.
[ "$(gc_repo_git cat-file -t "${tree}")" = tree ] || gc_refuse "--tree ${tree} is not a tree in ${repo}"
tree=${object}
set --
while IFS= read -r given; do
	resolve "${given}" commit --parent
	set -- "$@" -p "${object}"
done <"${gc_work}/args"
gc_read_identity "${effort}" "${repo}"
gc_effort_message "${message_file}" "${repo}"

gc_run_signed "${repo}" commit-tree -S "${tree}" "$@" -F "${gc_work}/message"
signed=true
if [ "${gc_sign_rc}" -ne 0 ] || ! IFS= read -r made <"${gc_work}/signed-out" || [ -z "${made}" ]; then
	signed=false
	gc_sign_reason=${gc_sign_reason:-git commit-tree -S printed no commit}
	made=$(gc_identity_git "${repo}" commit-tree "${tree}" "$@" -F "${gc_work}/message" </dev/null 2>"${gc_work}/stderr") ||
		fail "git commit-tree failed: $(head -n 1 "${gc_work}/stderr")"
	gc_say_unsigned
fi
jq -nc --arg commit "${made}" --argjson signed "${signed}" '{commit: $commit, signed: $signed}'
