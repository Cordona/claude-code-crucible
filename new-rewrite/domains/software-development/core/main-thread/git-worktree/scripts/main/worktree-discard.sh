#!/usr/bin/env sh
# Clears a tree's uncommitted changes after keeping them as a commit under a
# kept ref, and records it as worktree.discarded.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2310,SC2312 # each gw_ function exits on its own failure, and one in a condition is there for its status; a read inside a test or a message gives an empty or wrong value the test then refuses, or only shortens the message
set -eu
caller_umask=$(umask)
umask 077

usage() {
	cat <<'USAGE'
usage: sh worktree-discard.sh --effort FOLDER --name NAME

Clears a live tree's uncommitted changes (ignored files stay), keeping them
first as one commit under a new kept ref. Use it before worktree-drop.sh.

Options:
  --effort FOLDER  the effort's folder, absolute
  --name NAME      a live tree of the effort
Requires:  the effort open, with an identity for the tree's repository; the
           tree changed, idle, with no merge, pick, revert or rebase
Writes:    refs/crucible/discarded/<effort folder name>/NAME/<n>; the tree
           reset to HEAD, untracked files removed; worktree.discarded
           {name, kept, signed}
Stdout:    the event's path
Exit:
  0  discarded
  2  refused, nothing changed; the reason is on stderr
  4  git or a neighbour failed; after the kept ref, stderr names it and the
     tree may be partly cleared
  6  the events lock stayed held, nothing changed: rerun
USAGE
}

gw_prog='worktree-discard.sh'
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
gw_load_tree "${name}"
gw_require_present
gw_require_idle "${name}"
tree=${gw_tree_path}
going=$(gw_under_way "${tree}")
[ -z "${going}" ] || gw_refuse "tree ${name} has ${going} under way; finish or abort it first"
[ "$(gw_uncommitted "${tree}")" -gt 0 ] || gw_refuse "tree ${name} has nothing uncommitted to discard"

gw_changes_tree "${tree}" "${gw_head}"
gw_message discard 'uncommitted changes' "${name}"
made=$(sh "${gw_commit_object}" --repo "${tree}" --tree "${gw_changes}" --parent "${gw_head}" \
	--message-file "${gw_work}/message" --effort "${effort}") || exit $?
kept_commit=$(printf '%s' "${made}" | jq -r '.commit')
signed=$(printf '%s' "${made}" | jq -r '.signed')
kept=$(sh "${gw_scripts}/internal/worktree-kept.sh" --effort "${effort}" --name "${name}" --next discarded) || exit $?
kept=$(printf '%s' "${kept}" | jq -r '.next')
index=$(git -C "${tree}" rev-parse --path-format=absolute --git-path index) \
	|| gw_fail "could not find tree ${name}'s index; nothing was cleared"
cp -p -- "${index}" "${gw_work}/index" || gw_fail "could not save tree ${name}'s index; nothing was cleared"
git -C "${gw_tree_repo}" update-ref -m "${gw_prog}: kept before clearing ${name}" "${kept}" "${kept_commit}" '' \
	|| gw_fail "could not write the kept ref ${kept}; nothing was cleared"

(umask "${caller_umask}" && git -C "${tree}" -c core.hooksPath=/dev/null -c core.fsmonitor=false reset --quiet --hard HEAD) \
	2>"${gw_work}/stderr" || gw_fail "git reset --hard failed, the changes are kept under ${kept}: $(head -n 1 "${gw_work}/stderr")"
git -C "${tree}" -c core.fsmonitor=false clean -f -d --quiet 2>"${gw_work}/stderr" \
	|| gw_fail "git clean failed, the changes are kept under ${kept}: $(head -n 1 "${gw_work}/stderr")"
[ "$(gw_uncommitted "${tree}")" -eq 0 ] || gw_fail "tree ${name} is not clean after the reset; the changes are kept under ${kept}"

jq -n --arg name "${name}" --arg kept "${kept}" --argjson signed "${signed}" '{name: $name, kept: $kept, signed: $signed}' >"${gw_work}/body"

# Puts the kept work back into the tree's files and index, then deletes
# the kept ref.
undo_discard() {
	if gw_tree_still_there; then
		(umask "${caller_umask}" && git -C "${tree}" -c core.hooksPath=/dev/null -c core.fsmonitor=false restore --source="${kept_commit}" --worktree -- :/) \
			2>"${gw_work}/stderr" || gw_fail "worktree.discarded was not written, and putting the work back failed; it is kept under ${kept}: $(head -n 1 "${gw_work}/stderr")"
		cp -p -- "${gw_work}/index" "${index}" || gw_fail "worktree.discarded was not written, and the index could not be put back; the work is kept under ${kept}"
		printf '%s: worktree.discarded was not written; tree %s holds its changes again\n' "${gw_prog}" "${name}" >&2
	fi
	gw_delete_kept "${kept}" "${kept_commit}"
}
gw_write_or_undo worktree.discarded "${gw_work}/body" undo_discard
printf '%s\n' "${gw_event}"
