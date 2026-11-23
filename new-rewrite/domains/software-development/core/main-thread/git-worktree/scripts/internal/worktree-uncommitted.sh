#!/usr/bin/env sh
# Counts the paths with an uncommitted change in a worktree folder. Reads
# only.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2310,SC2312 # each gw_ function exits on its own failure, and one in a condition is there for its status; a read inside a message only shortens the message
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh worktree-uncommitted.sh --dir FOLDER

Run by the git-worktree scripts; not for main to call.
Counts the paths with an uncommitted change in the git work tree FOLDER is
in. Use it to check that a checkout or tree is clean.

Options:
  --dir FOLDER  a folder in a git work tree, absolute
Writes:    nothing
Stdout:    one JSON line {"uncommitted": N}; 0 means clean. N counts each
           staged, unstaged and untracked file (a rename once); never
           ignored files
Exit:
  0  counted, whatever N is
  2  refused, nothing changed; the reason is on stderr
  4  git status failed: FOLDER is missing or not in a work tree, or git
     or jq is not installed
USAGE
}

gw_prog='worktree-uncommitted.sh'
. "$(dirname -- "$0")/../lib/git-worktree.sh"
dir=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--dir) [ $# -ge 2 ] || gw_refuse '--dir needs a value'; dir=$2; shift 2 ;;
		*) gw_refuse "unknown argument $1; try --help" ;;
	esac
done
case ${dir} in
	'') gw_refuse '--dir needs a value' ;;
	/*) ;;
	*) gw_refuse '--dir must be an absolute folder' ;;
esac
command -v git >/dev/null 2>&1 || gw_fail 'git not found'
command -v jq >/dev/null 2>&1 || gw_fail 'jq not found'
gw_make_work
git -C "${dir}" -c core.fsmonitor=false status --porcelain=v1 -z --untracked-files=all >"${gw_work}/status" \
	|| gw_fail "git status failed in $(gw_printable "${dir}")"
jq -c -R -s -L "$(dirname -- "$0")/../lib" 'include "uncommitted"; {uncommitted: ([uncommitted_paths] | length)}' "${gw_work}/status"
