#!/usr/bin/env sh
# Removes one tree of the effort with its registration, branch and kept
# refs, and records it as worktree.dropped; unlanded work needs the human's
# recorded yes.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2310,SC2312 # each gw_ function exits on its own failure, and one in a condition is there for its status; a read inside a test or a message gives an empty or wrong value the test then refuses, or only shortens the message
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh worktree-drop.sh --effort FOLDER --name NAME

Removes the effort's live tree NAME for good, in any effort state, closed
included. Use it to clear a tree whose work is done or no longer wanted.

Options:
  --effort FOLDER  the effort's folder, absolute
  --name NAME      a live tree of the effort
Requires:  no uncommitted changes (commit them, or keep them with
           worktree-discard.sh) and nothing working in it (worktree-busy.sh);
           the human's recorded yes, unused and given since the cut, when its
           branch or kept refs hold commits the checkout and bases lack (today,
           any it made) or its folder and branch are both gone: record
           drop-worktree, subject "NAME:<full branch tip SHA>" or "NAME:none"
Writes:    deletes the folder (untracked too; gone by hand is fine), the
           registration, branch and kept refs; worktree.dropped {name, answer?}
Stdout:    one path, the event's
Exit:
  0  dropped
  2  refused, nothing changed; the reason is on stderr
  4  git or a tool failed, part may be removed: rerun to drop the rest
  6  the events lock stayed held after the removal: rerun, the same yes holds
USAGE
}

# Prints how many commits the tip and the kept refs hold that neither the
# checkout's HEAD nor the tree's bases hold.
count_unlanded() {
	set --
	[ -z "${tip}" ] || set -- "${tip}"
	while IFS= read -r ref; do set -- "$@" "${ref}"; done <"${gw_work}/kept"
	[ $# -gt 0 ] || { echo 0; return; }
	set -- "$@" --not
	checkout_head=$(git -C "${repo}" rev-parse --verify --quiet 'HEAD^{commit}') || checkout_head=''
	for held in "${checkout_head}" "${gw_tree_cut_base}" "${gw_tree_base}"; do
		[ -z "${held}" ] || ! git -C "${repo}" cat-file -e "${held}^{commit}" 2>/dev/null || set -- "$@" "${held}"
	done
	git -C "${repo}" rev-list --count "$@" || gw_fail "git rev-list failed in ${repo}"
}

# Prints how many worktree.dropped events carry answer $1.
answer_uses() {
	jq --argjson a "$1" '[.[] | select(.type == "worktree.dropped" and .body.answer == $a)] | length' "${gw_work}/events"
}

# A tree whose folder and branch are both gone was removed by a drop that
# could not write its event. Prints the seq of the newest yes the human
# gave for this tree since its cut that no drop has used yet, the one that
# drop read; refuses when there is none.
rerun_yes() {
	sh "${gw_core_answer}" --effort "${effort}" --record drop-worktree --subject-prefix "${name}:" \
		--after "${cut_seq}" >"${gw_work}/answers" || gw_fail 'gate-answer.sh failed listing the drop answers'
	jq -r --arg prefix "${name}:" '.answers | reverse | .[]
		| select(.subject | ltrimstr($prefix) | test("^([0-9a-f]{40}|[0-9a-f]{64}|none)$")) | .seq' \
		"${gw_work}/answers" >"${gw_work}/seqs"
	best=''
	while IFS= read -r seq; do
		[ "$(answer_uses "${seq}")" -eq 0 ] || continue
		best=${seq}
		break
	done <"${gw_work}/seqs"
	[ -n "${best}" ] || gw_refuse "tree ${name}'s folder and branch are gone and no unused recorded yes since its cut names it; record drop-worktree, subject ${name}:none"
	echo "${best}"
}

gw_prog='worktree-drop.sh'
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
gw_check_name "${name}"
gw_make_work
gw_read_events
gw_load_tree "${name}"
gw_require_idle "${name}"
repo=${gw_tree_repo}
path=${gw_tree_path}
cut_seq=$(printf '%s' "${gw_tree}" | jq -r '.seq')
[ -d "${repo}/.git" ] || gw_refuse "the repository ${repo} is not there"

present=no
if [ -e "${path}" ] || [ -L "${path}" ]; then
	top=$(git -C "${path}" rev-parse --show-toplevel 2>/dev/null) || top=''
	[ "${top}" = "${path}" ] || gw_refuse "${path} is there but is no git worktree; remove it by hand, then drop again"
	present=yes
	changed=$(gw_uncommitted "${path}")
	[ "${changed}" -eq 0 ] \
		|| gw_refuse "tree ${name} has ${changed} uncommitted changes; discard them first (worktree-discard.sh keeps them) or commit them"
fi

tip=$(gw_branch_tip)
kept_refs=$(sh "${gw_scripts}/internal/worktree-kept.sh" --effort "${effort}" --name "${name}") || exit $?
printf '%s' "${kept_refs}" | jq -r '.kept[]' >"${gw_work}/kept"

answer=''
if [ -z "${tip}" ] && [ "${present}" = no ]; then
	answer=$(rerun_yes)
else
	unlanded=$(count_unlanded)
	if [ "${unlanded}" -gt 0 ]; then
		subject="${name}:${tip:-none}"
		said=$(sh "${gw_core_answer}" --effort "${effort}" --record drop-worktree --subject "${subject}" 2>/dev/null) \
			|| gw_refuse "tree ${name} holds ${unlanded} unlanded commits; it needs the human's recorded yes (record drop-worktree, subject ${subject})"
		answer=${said#ACCEPTED: }
		[ "$(answer_uses "${answer}")" -eq 0 ] || gw_refuse "the human's yes ${answer} already dropped a tree; ask again for ${subject}"
	fi
fi

if [ "${present}" = yes ]; then
	git -C "${repo}" -c core.hooksPath=/dev/null worktree remove --force "${path}" 2>"${gw_work}/stderr" \
		|| gw_fail "git worktree remove failed: $(head -n 1 "${gw_work}/stderr")"
else
	# The folder went by hand: only this tree's own registration is removed,
	# never another stale one.
	for entry_gitdir in "${repo}"/.git/worktrees/*/gitdir; do
		[ -f "${entry_gitdir}" ] || continue
		[ "$(cat -- "${entry_gitdir}")" = "${path}/.git" ] || continue
		rm -rf -- "${entry_gitdir%/gitdir}" || gw_fail "could not remove the registration ${entry_gitdir%/gitdir}"
	done
fi
[ -z "${tip}" ] || git -C "${repo}" update-ref -d "refs/heads/${gw_tree_branch}" \
	|| gw_fail "could not delete the branch ${gw_tree_branch}"
while IFS= read -r ref; do
	git -C "${repo}" update-ref -d "${ref}" || gw_fail "could not delete the kept ref ${ref}"
done <"${gw_work}/kept"
! git -C "${repo}" worktree list --porcelain | grep -qxF "worktree ${path}" \
	|| gw_fail "${path} is still registered in ${repo}"

jq -n --arg name "${name}" --arg answer "${answer}" \
	'{name: $name} + (if $answer == "" then {} else {answer: ($answer | tonumber)} end)' >"${gw_work}/body"
gw_write worktree.dropped "${gw_work}/body"
