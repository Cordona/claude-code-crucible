#!/usr/bin/env sh
# Takes a commit into a tree's branch, or aborts a merge left there, and
# records the result as worktree.synced.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2310,SC2312 # each gw_ function exits on its own failure, and one in a condition is there for its status; a read inside a test or a message gives an empty or wrong value the test then refuses, or only shortens the message
set -eu
caller_umask=$(umask)
umask 077

usage() {
	cat <<'USAGE'
usage: sh worktree-catch-up.sh --effort FOLDER --name NAME --with REF
       sh worktree-catch-up.sh --effort FOLDER --name NAME --abort

Brings the effort's live tree NAME up to date with a commit, or cancels a
merge left there. For the trees NAME was cut from: worktree-chain-sync.sh.

Options:
  --effort FOLDER  the effort's folder, absolute
  --name NAME      a live tree of the effort
  --with REF       a commit git resolves in the tree (sha, branch, tag);
                   result in_sync (already held), merged (fast-forward to a
                   sync commit made as the effort, or to REF), or conflict
                   (merge left: resolve, then git-commit's commit-tree.sh)
  --abort          cancel that merge; result aborted, the tree clean at tip
Requires:  open effort; nothing working in the tree; --with: clean, no
           op under way, REF fetched, an identity (git-identity) to merge
Writes:    the tree's branch, index and files; one worktree.synced event
Stdout:    {event (its path), result, commit?, signed?, conflicts? (paths)}
Exit:
  0  in_sync, merged, conflict or aborted: read result
  2  refused, nothing changed; the reason is on stderr
  4  git or a neighbour failed; the tree may have changed
  6  the events lock stayed held, nothing changed: rerun
USAGE
}

gw_prog='worktree-catch-up.sh'
. "$(dirname -- "$0")/../lib/git-worktree.sh"
effort='' name='' with='' abort=no
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--abort) abort=yes; shift ;;
		--effort | --name | --with)
			[ $# -ge 2 ] || gw_refuse "$1 needs a value"
			case $1 in --effort) effort=$2 ;; --name) name=$2 ;; --with) with=$2 ;; *) ;; esac
			shift 2 ;;
		*) gw_refuse "unknown argument $1; try --help" ;;
	esac
done
case ${abort}:${with} in
	yes:) ;;
	yes:*) gw_refuse '--abort and --with exclude each other' ;;
	no:) gw_refuse '--with REF or --abort is needed' ;;
	*) ;;
esac
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
ident_name='' ident_email=''
# git merge wants a committer even when it stops before committing: the
# effort's identity, as git-commit uses for every commit.
merge_git() {
	(umask "${caller_umask}" && exec git -C "${tree}" -c core.hooksPath=/dev/null -c core.fsmonitor=false \
		-c rerere.enabled=false ${ident_name:+-c "user.name=${ident_name}"} ${ident_email:+-c "user.email=${ident_email}"} \
		"$@" </dev/null)
}

# Writes worktree.synced from JSON body $2 and prints the result line,
# adding the JSON fields $3 to it; when the write fails, function $1 undoes
# the change.
record() {
	printf '%s' "$2" >"${gw_work}/body"
	gw_write_or_undo worktree.synced "${gw_work}/body" "$1"
	more=${3-}
	[ -n "${more}" ] || more='{}'
	printf '%s' "$2" | jq -c --arg e "${gw_event}" --argjson more "${more}" \
		'{event: $e, result} + (if has("commit") then {commit, signed} else {} end) + $more'
}

# The undo for each result, once worktree.synced could not be written.
undo_none() { :; }
undo_merged() {
	gw_tree_still_there || return 0
	merge_git reset --quiet --keep "${before}" 2>"${gw_work}/stderr" \
		|| gw_fail "worktree.synced was not written, and git reset --keep ${before} failed: $(head -n 1 "${gw_work}/stderr")"
	printf '%s: worktree.synced was not written; tree %s is back at %s\n' "${gw_prog}" "${name}" "${before}" >&2
}
undo_conflict() {
	gw_tree_still_there || return 0
	merge_git merge --abort >/dev/null 2>"${gw_work}/stderr" \
		|| gw_fail "worktree.synced was not written, and git merge --abort failed: $(head -n 1 "${gw_work}/stderr")"
	printf '%s: worktree.synced was not written; the merge in tree %s is taken out again\n' "${gw_prog}" "${name}" >&2
}
undo_aborted() {
	gw_tree_still_there || return 0
	use_identity
	merge_git merge --no-ff --no-commit --no-verify-signatures --no-autostash --quiet "${merge_head}" >/dev/null 2>&1 || :
	[ "$(git -C "${tree}" rev-parse --verify --quiet MERGE_HEAD || :)" = "${merge_head}" ] \
		|| gw_fail "worktree.synced was not written, and the merge of ${merge_head} could not be started again"
	printf '%s: worktree.synced was not written; the merge of %s is under way again, without resolutions made before the abort\n' "${gw_prog}" "${merge_head}" >&2
}

# Sets the committer git merge needs to the effort's identity.
use_identity() {
	identity=$(sh "${gw_skills}/git-identity/scripts/main/identity-get.sh" --effort "${effort}" --repo "${tree}") \
		|| gw_fail "identity-get.sh could not read the effort's identity for the merge"
	ident_name=$(printf '%s' "${identity}" | jq -r '.name')
	ident_email=$(printf '%s' "${identity}" | jq -r '.email')
}

# Refuses unless the tree is back at its tip, on its branch and clean.
require_settled() {
	[ "$(git -C "${tree}" rev-parse --verify --quiet HEAD || :)" = "${gw_head}" ] \
		|| gw_fail "tree ${name}'s HEAD is not ${gw_head} after $1"
	[ "$(gw_uncommitted "${tree}")" -eq 0 ] || gw_fail "tree ${name} is not clean after $1"
}

if [ "${abort}" = yes ]; then
	merge_head=$(git -C "${tree}" rev-parse --verify --quiet MERGE_HEAD) || gw_refuse "tree ${name} has no merge under way"
	merge_git merge --abort >/dev/null 2>"${gw_work}/stderr" \
		|| gw_fail "git merge --abort failed: $(head -n 1 "${gw_work}/stderr")"
	require_settled 'the abort'
	record undo_aborted "$(jq -nc --arg n "${name}" --arg w "${merge_head}" '{name: $n, with: $w, result: "aborted"}')"
	exit 0
fi

going=$(gw_under_way "${tree}")
[ -z "${going}" ] || gw_refuse "tree ${name} has ${going} under way; finish it, or abort a merge with --abort"
changed=$(gw_uncommitted "${tree}")
[ "${changed}" -eq 0 ] || gw_refuse "tree ${name} has ${changed} uncommitted changes; expected a clean tree"
with_sha=$(gw_resolve_commit "${with}" "${tree}" --with)

if git -C "${tree}" merge-base --is-ancestor "${with_sha}" "${gw_head}"; then
	record undo_none "$(jq -nc --arg n "${name}" --arg w "${with_sha}" '{name: $n, with: $w, result: "in_sync"}')"
	exit 0
fi

short=$(git -C "${tree}" rev-parse --short=12 "${with_sha}")
gw_message sync "take in ${short}" "${name}"
rc=0
made=$(sh "${gw_commits_merge}" --repo "${tree}" --commit "${gw_head}" --commit "${with_sha}" \
	--message-file "${gw_work}/message" --effort "${effort}" 2>"${gw_work}/merge-stderr") || rc=$?
case ${rc} in
	0)
		cat "${gw_work}/merge-stderr" >&2
		commit=$(printf '%s' "${made}" | jq -r '.commit')
		signed=$(printf '%s' "${made}" | jq -r '.signed')
		merge_git merge --ff-only --quiet --no-verify-signatures --no-autostash "${commit}" >/dev/null 2>"${gw_work}/stderr" \
			|| gw_fail "the fast-forward of ${gw_tree_branch} to ${commit} failed: $(head -n 1 "${gw_work}/stderr")"
		before=${gw_head} gw_head=${commit}
		require_settled 'the fast-forward'
		record undo_merged "$(jq -nc --arg n "${name}" --arg w "${with_sha}" --arg c "${commit}" --argjson s "${signed}" \
			'{name: $n, with: $w, result: "merged", commit: $c, signed: $s}')"
		;;
	3)
		use_identity
		merge_rc=0
		merge_git merge --no-ff --no-commit --no-verify-signatures --no-autostash --quiet "${with_sha}" \
			>/dev/null 2>"${gw_work}/stderr" || merge_rc=$?
		[ "$(git -C "${tree}" rev-parse --verify --quiet MERGE_HEAD || :)" = "${with_sha}" ] \
			|| gw_fail "git merge (exit ${merge_rc}) left no merge of ${short} under way: $(head -n 1 "${gw_work}/stderr")"
		git -C "${tree}" diff --name-only --diff-filter=U -z >"${gw_work}/conflicts" \
			|| gw_fail 'git diff --diff-filter=U failed'
		if [ ! -s "${gw_work}/conflicts" ]; then
			merge_git merge --abort >/dev/null 2>&1 || :
			gw_fail "commits-merge.sh found a conflict that git merge did not; the merge is aborted"
		fi
		conflicts=$(jq -Rsc 'split("\u0000") | map(select(. != ""))' "${gw_work}/conflicts")
		record undo_conflict "$(jq -nc --arg n "${name}" --arg w "${with_sha}" '{name: $n, with: $w, result: "conflict"}')" \
			"$(jq -nc --argjson c "${conflicts}" '{conflicts: $c}')"
		;;
	*)
		cat "${gw_work}/merge-stderr" >&2
		exit "${rc}"
		;;
esac
