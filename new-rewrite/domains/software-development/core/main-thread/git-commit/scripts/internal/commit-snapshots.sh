#!/usr/bin/env sh
# Tells which of the given commits are snapshots, by the subject git-commit's
# message rule gives a snapshot. Reads only.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2310,SC2312 # gc_repo_git in a condition is one git command, its failure refused; a read inside a message only shortens the message
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh commit-snapshots.sh --repo DIR --commit SHA [--commit SHA]...

Run by effort-commits.sh; not for main to call.
Tells which of the given commits are snapshots: commits of a checkout's
uncommitted work, made with the message kind snapshot.

Options:
  --repo DIR    a folder in the repository or a worktree, absolute
  --commit SHA  a commit to tell; repeatable
Writes:    nothing
Stdout:    one JSON line {"snapshots": [SHA...]}: the given commits that are
           snapshots, as full shas, in the order given
Exit:
  0  told
  2  refused, nothing changed; the reason is on stderr
  4  git or jq failed; the reason is on stderr
USAGE
}

gc_prog='commit-snapshots.sh'
. "$(dirname -- "$0")/../lib/git-commit.sh"

fail() {
	printf '%s: %s\n' "${gc_prog}" "$1" >&2
	exit 4
}

repo=''
gc_make_work
: >"${gc_work}/given"
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--repo | --commit)
			[ $# -ge 2 ] && [ -n "$2" ] || gc_refuse "$1 needs a value"
			case $1 in --repo) repo=$2 ;; --commit) printf '%s\n' "$2" >>"${gc_work}/given" ;; *) ;; esac
			shift 2 ;;
		*) gc_refuse "unknown argument $(printf '%s' "$1" | tr '[:cntrl:]' '?'); try --help" ;;
	esac
done
[ -n "${repo}" ] || gc_refuse '--repo missing'
[ -s "${gc_work}/given" ] || gc_refuse '--commit missing; expected one or more'
command -v git >/dev/null 2>&1 || fail 'git not found'
command -v jq >/dev/null 2>&1 || fail 'jq not found'
gc_find_neighbours "$0"
gc_check_repo "${repo}"

set --
while IFS= read -r given; do
	case ${given} in
		-*) gc_refuse "--commit $(printf '%s' "${given}" | tr '[:cntrl:]' '?') starts with -; expected a commit" ;;
		*) ;;
	esac
	commit=$(gc_repo_git rev-parse --verify --quiet --end-of-options "${given}^{commit}" 2>/dev/null) ||
		gc_refuse "--commit $(printf '%s' "${given}" | tr '[:cntrl:]' '?') is no commit in ${repo}"
	set -- "$@" "${commit}"
done <"${gc_work}/given"

gc_repo_git log --no-walk=unsorted --no-show-signature -z --format='%H%n%s' "$@" -- \
	>"${gc_work}/subjects" 2>"${gc_work}/stderr" || fail "git log failed: $(head -n 1 "${gc_work}/stderr")"
jq -Rsc -L "$(dirname -- "$0")/../lib" 'include "commit-message";
	{snapshots: [split("\u0000")[] | select(. != "") | split("\n") | select(.[1:] | join("\n") | commit_is_snapshot) | .[0]]}' \
	<"${gc_work}/subjects" || fail 'jq failed; expected jq 1.6+ and commit-message.jq in scripts/lib/'
