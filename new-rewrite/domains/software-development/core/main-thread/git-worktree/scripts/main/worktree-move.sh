#!/usr/bin/env sh
# Moves a clean tree's branch to another commit for new work, keeping the
# old tip when commits would be left out, and records it as worktree.moved.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2310,SC2312 # each gw_ function exits on its own failure, and one in a condition is there for its status; a read inside a test or a message gives an empty or wrong value the test then refuses, or only shortens the message
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh worktree-move.sh --effort FOLDER --name NAME --to REF

Points a live tree's branch and files at REF, so new work starts there. To
take REF into the tree's work instead, use worktree-catch-up.sh.

Options:
  --effort FOLDER  the effort's folder, absolute
  --name NAME      a live tree of the effort
  --to REF         a commit of the tree's repository: sha, branch, tag
Requires:  the effort open; the tree on its branch, clean, idle, with no
           merge, pick, revert or rebase under way
Writes:    the tree's branch and files; the old tip kept at
           refs/crucible/moved/<effort folder>/NAME/<n> when REF lacks it;
           worktree.moved {name, from, to, kept?}; nothing when at REF
Stdout:    the event's absolute path, or "in place <sha>"
Exit:
  0  moved, or already in place
  2  refused, nothing changed; the reason is on stderr
  4  git or the busy check failed; the branch did not move
  6  the events lock stayed held, nothing changed: rerun
USAGE
}

gw_prog='worktree-move.sh'
. "$(dirname -- "$0")/../lib/git-worktree.sh"
effort='' name='' to=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--effort | --name | --to)
			[ $# -ge 2 ] || gw_refuse "$1 needs a value"
			case $1 in --effort) effort=$2 ;; --name) name=$2 ;; --to) to=$2 ;; *) ;; esac
			shift 2 ;;
		*) gw_refuse "unknown argument $1; try --help" ;;
	esac
done
gw_find_core "$0"
gw_check_effort "${effort}"
gw_require_open
gw_check_name "${name}"
gw_make_work
gw_load_tree "${name}"
gw_require_present
gw_require_idle "${name}"
going=$(gw_under_way "${gw_tree_path}")
[ -z "${going}" ] || gw_refuse "tree ${name} has ${going} under way; finish or abort it first"
changed=$(gw_uncommitted "${gw_tree_path}")
[ "${changed}" -eq 0 ] || gw_refuse "tree ${name} has ${changed} uncommitted changes; expected a clean tree"
to_sha=$(gw_resolve_commit "${to}" "${gw_tree_path}" --to)
if [ "${to_sha}" = "${gw_head}" ]; then
	printf 'in place %s\n' "${to_sha}"
	exit 0
fi

kept=''
ancestor_rc=0
git -C "${gw_tree_path}" merge-base --is-ancestor "${gw_head}" "${to_sha}" || ancestor_rc=$?
case ${ancestor_rc} in
	0) ;;
	1)
		kept=$(sh "${gw_scripts}/internal/worktree-kept.sh" --effort "${effort}" --name "${name}" --next moved) || exit $?
		kept=$(printf '%s' "${kept}" | jq -r '.next')
		git -C "${gw_tree_repo}" update-ref -m "${gw_prog}: kept before moving to ${to_sha}" "${kept}" "${gw_head}" '' \
			|| gw_fail "could not write the kept ref ${kept}; nothing was moved"
		;;
	*) gw_fail "git merge-base --is-ancestor failed in ${gw_tree_path}" ;;
esac
if ! git -C "${gw_tree_path}" -c core.hooksPath=/dev/null -c core.fsmonitor=false reset --quiet --keep "${to_sha}" 2>"${gw_work}/stderr"; then
	[ -z "${kept}" ] || git -C "${gw_tree_repo}" update-ref -d "${kept}" "${gw_head}" \
		|| printf '%s: could not delete %s; delete it with git update-ref -d\n' "${gw_prog}" "${kept}" >&2
	gw_fail "git reset --keep ${to_sha} failed: $(head -n 1 "${gw_work}/stderr")"
fi

jq -n --arg name "${name}" --arg from "${gw_head}" --arg to "${to_sha}" --arg kept "${kept}" \
	'{name: $name, from: $from, to: $to} + (if $kept == "" then {} else {kept: $kept} end)' >"${gw_work}/body"

# Puts the branch back at its old tip and deletes the kept ref made.
undo_move() {
	if gw_tree_still_there; then
		git -C "${gw_tree_path}" -c core.hooksPath=/dev/null -c core.fsmonitor=false reset --quiet --keep "${gw_head}" 2>"${gw_work}/stderr" \
			|| gw_fail "worktree.moved was not written, and git reset --keep ${gw_head} failed: $(head -n 1 "${gw_work}/stderr")"
		printf '%s: worktree.moved was not written; tree %s is back at %s\n' "${gw_prog}" "${name}" "${gw_head}" >&2
	fi
	[ -z "${kept}" ] || gw_delete_kept "${kept}" "${gw_head}"
}
gw_write_or_undo worktree.moved "${gw_work}/body" undo_move
printf '%s\n' "${gw_event}"
