#!/usr/bin/env sh
# Prints the effort's live trees, one line each: the open-work contract.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2310,SC2312 # each gw_ function exits on its own failure, and one in a condition is there for its status; a read inside a test or a message gives an empty or wrong value the test then refuses, or only shortens the message
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh open-work.sh --effort FOLDER

Run by crucible-effort's effort-close.sh; not for main to call.
Lists the effort's live worktrees: made and not yet dropped.

Options:
  --effort FOLDER  the effort's folder, absolute
Writes:    nothing
Stdout:    one line per live tree, oldest first, `worktree <name> <path>`;
           nothing when none is live
Exit:
  0  checked; the lines are the live trees
  2  refused, nothing changed; the reason is on stderr
  4  git or jq not found
USAGE
}

gw_prog='open-work.sh'
. "$(dirname -- "$0")/../lib/git-worktree.sh"
effort=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--effort) [ $# -ge 2 ] || gw_refuse '--effort needs a value'; effort=$2; shift 2 ;;
		*) gw_refuse "unknown argument $1; try --help" ;;
	esac
done
gw_find_core "$0"
gw_check_effort "${effort}"
sh "${gw_scripts}/internal/worktree-trees.sh" --effort "${gw_effort_given}" | jq -r '.[] | "worktree \(.name) \(.path)"'
