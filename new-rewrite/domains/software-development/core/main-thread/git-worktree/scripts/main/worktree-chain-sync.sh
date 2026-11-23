#!/usr/bin/env sh
# Takes into a tree the tip of every tree it was cut from that moved on,
# through worktree-catch-up.sh.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2310,SC2312 # each gw_ function exits on its own failure, and one in a condition is there for its status; a read inside a test or a message gives an empty or wrong value the test then refuses, or only shortens the message
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh worktree-chain-sync.sh --effort FOLDER --name NAME

Takes into the effort's live tree NAME the new work of every tree it was cut
from, at any level. Use it once the human decides NAME should take that work
in, e.g. after worktree-chain.sh shows an ancestor moved.

Options:
  --effort FOLDER  the effort's folder, absolute
  --name NAME      a live tree of the effort
Requires:  open effort, an identity (git-identity) for the repository; NAME
           clean, no git operation under way, not busy (worktree-busy.sh)
Writes:    if any moved, NAME's branch and folder and one worktree.synced event
Stdout:    {"result":"in_sync"} if none moved; else {event (its path), result,
           commit?, signed?, conflicts? (paths)}; exit 3: {"conflicts": [PATH]}
Exit:
  0  in_sync, merged, or conflict (merge left in NAME): read result; see
     worktree-catch-up.sh --help to finish or --abort it
  2  refused, nothing changed; the reason is on stderr
  3  the moved trees' tips conflict with each other; nothing changed: take
     them in one at a time (worktree-catch-up.sh --with) or ask the human
  4  git or a neighbour failed; the tree may have changed
  6  the events lock stayed held, nothing changed: rerun
USAGE
}

gw_prog='worktree-chain-sync.sh'
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
gw_find_commit
gw_check_effort "${effort}"
gw_require_open
gw_check_name "${name}"
gw_make_work
chain=$(sh "${gw_scripts}/main/worktree-chain.sh" --effort "${effort}" --name "${name}") || exit $?
moved=$(printf '%s' "${chain}" | jq -r '[.ancestors[] | select(.held | not) | .tip] | unique | join(" ")')
if [ -z "${moved}" ]; then
	printf '{"result":"in_sync"}\n'
	exit 0
fi
case ${moved} in
	*' '*)
		gw_load_tree "${name}"
		names=$(printf '%s' "${chain}" | jq -r '[.ancestors[] | select(.held | not) | .name] | join(" ")')
		gw_message sync 'join the trees a tree was cut from' "${names}"
		rc=0
		# shellcheck disable=SC2086 # the tips are full shas, split on purpose
		made=$(sh "${gw_commits_merge}" --repo "${gw_tree_path}" --commit ${moved} \
			--message-file "${gw_work}/message" --effort "${effort}") || rc=$?
		case ${rc} in
			0) take=$(printf '%s' "${made}" | jq -r '.commit') ;;
			3)
				printf '%s\n' "${made}"
				printf '%s: the moved trees %s conflict in %s; nothing changed\n' "${gw_prog}" "${names}" \
					"$(printf '%s' "${made}" | jq -r '.conflicts | join(", ")')" >&2
				exit 3
				;;
			*) exit "${rc}" ;;
		esac
		;;
	*) take=${moved} ;;
esac
sh "${gw_scripts}/main/worktree-catch-up.sh" --effort "${effort}" --name "${name}" --with "${take}"
