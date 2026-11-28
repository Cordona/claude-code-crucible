#!/usr/bin/env sh
# Prints an effort's live trees, read from its worktree.* events. Reads only.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2310,SC2312 # each gw_ function exits on its own failure, and one in a condition is there for its status; a read inside a message only shortens the message
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh worktree-trees.sh --effort FOLDER [--name NAME]

Run by the git-worktree scripts, mount-apply.sh and push-tree.sh; not for main
to call.
Prints the effort's live trees (cut, not dropped), oldest cut first. Use it to
find a tree's path, branch, repo or base before acting on it.

Options:
  --effort FOLDER  an effort folder, absolute; open or not
  --name NAME      only the live tree of that name
Writes:    nothing
Stdout:    one JSON line, [{name, repo, path, branch, from, cut_base, base,
           seq}...], [] when none match; repo the main checkout; from as the
           cut asked; cut_base the SHA cut at; base the newest move's target
           SHA, else cut_base; seq the cut's event number
Exit:
  0  listed
  2  refused, nothing changed; the reason is on stderr
  4  reading the events failed, or git or jq is missing: fix, rerun
USAGE
}

gw_prog='worktree-trees.sh'
. "$(dirname -- "$0")/../lib/git-worktree.sh"
effort='' name=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--effort | --name)
			[ $# -ge 2 ] || gw_refuse "$1 needs a value"
			case $1 in --effort) effort=$2 ;; --name) name=$2 ;; *) ;; esac
			shift 2 ;;
		*) gw_refuse "unknown argument $1; try --help" ;;
	esac
done
gw_find_core "$0"
gw_check_effort "${effort}"
[ -z "${name}" ] || gw_check_name "${name}"
gw_make_work
gw_read_events
jq -c -L "${gw_lib}" --arg n "${name}" 'include "trees"; live_trees | map(select($n == "" or .name == $n))' "${gw_work}/events"
