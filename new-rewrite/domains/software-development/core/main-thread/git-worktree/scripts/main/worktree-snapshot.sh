#!/usr/bin/env sh
# Makes one commit object of the checkout's uncommitted work, touching no
# ref, index or file of the human's.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2310,SC2312 # each gw_ function exits on its own failure, and one in a condition is there for its status; a read inside a test or a message gives an empty or wrong value the test then refuses, or only shortens the message
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh worktree-snapshot.sh --repo DIR --effort FOLDER

Makes one commit of the main checkout's uncommitted work (staged, unstaged,
untracked; not ignored) on HEAD, as the effort's identity, to base work on
the checkout as it is now.

Options:
  --repo DIR       a folder of the repository, absolute
  --effort FOLDER  the effort's folder, absolute
Requires:  the effort's identity for the repository; a HEAD commit; not
           sparse; no merge, rebase, cherry-pick or revert under way
Writes:    git objects only; no ref, index, file or event
Stdout:    {"commit": SHA, "new": BOOL, "signed": BOOL}: new false, nothing
           was uncommitted and commit is HEAD; signed false, unsigned
Exit:
  0  printed
  2  refused, nothing changed; the reason is on stderr
  4  git, jq or a neighbour failed: fix the reason on stderr, rerun
  5  the checkout changed during the run; nothing printed: rerun
USAGE
}

gw_prog='worktree-snapshot.sh'
. "$(dirname -- "$0")/../lib/git-worktree.sh"
repo_in='' effort=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--repo | --effort)
			[ $# -ge 2 ] || gw_refuse "$1 needs a value"
			case $1 in --repo) repo_in=$2 ;; --effort) effort=$2 ;; *) ;; esac
			shift 2 ;;
		*) gw_refuse "unknown argument $1; try --help" ;;
	esac
done
gw_find_core "$0"
gw_find_commit
gw_check_effort "${effort}"
gw_set_repo "${repo_in}"

git_dir="${gw_repo}/.git"
for state in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply; do
	[ ! -e "${git_dir}/${state}" ] || gw_refuse "the checkout ${gw_repo} has ${state} under way; expected none"
done
sparse=$(git -C "${gw_repo}" config --type=bool core.sparseCheckout 2>/dev/null) || sparse=false
[ "${sparse}" != true ] || gw_refuse "the checkout ${gw_repo} is sparse; files outside it would read as deleted"
git -C "${gw_repo}" rev-parse --verify --quiet 'HEAD^{commit}' >/dev/null || gw_refuse "the checkout ${gw_repo} has no HEAD commit"
identity_get="${gw_skills}/git-identity/scripts/main/identity-get.sh"
[ -f "${identity_get}" ] || gw_refuse "git-identity isn't beside this skill (expected ${identity_get}); install first"
rc=0
sh "${identity_get}" --effort "${effort}" --repo "${gw_repo}" >/dev/null 2>&1 || rc=$?
case ${rc} in
	0) ;;
	5) gw_refuse "the effort has no identity for ${gw_repo}; set the identity first (git-identity)" ;;
	*) gw_fail "identity-get.sh failed (exit ${rc})" ;;
esac
gw_make_work

# Prints what the snapshot must not move in the checkout.
fingerprint() {
	git -C "${gw_repo}" -c core.fsmonitor=false rev-parse --verify --quiet HEAD || gw_fail 'git could not read HEAD'
	git -C "${gw_repo}" symbolic-ref -q HEAD || printf 'detached\n'
	[ ! -f "${git_dir}/index" ] || cksum <"${git_dir}/index"
	git -C "${gw_repo}" -c core.fsmonitor=false status --porcelain=v1 -z --untracked-files=all | cksum
	git -C "${gw_repo}" for-each-ref --format='%(objectname)%09%(refname)' \
		| awk -F '\t' 'index($2, "refs/heads/crucible/") != 1 && index($2, "refs/crucible/") != 1 && index($2, "refs/remotes/") != 1' \
		| cksum
	git -C "${gw_repo}" stash list --format=%H | cksum
}

before=$(fingerprint) || gw_fail 'git could not read the checkout'
# The parent is the HEAD the fingerprint saw, so a HEAD moved since can't
# slip past the comparison.
head=$(printf '%s\n' "${before}" | head -n 1)
gw_changes_tree "${gw_repo}" "${head}"
if [ "${gw_changes}" = "${gw_head_tree}" ]; then
	signed=false
	! git -C "${gw_repo}" cat-file commit "${head}" | sed '/^$/q' | grep -q '^gpgsig' || signed=true
	result=$(jq -nc --arg c "${head}" --argjson s "${signed}" '{commit: $c, new: false, signed: $s}')
else
	gw_message snapshot 'uncommitted changes'
	made=$(sh "${gw_commit_object}" --repo "${gw_repo}" --tree "${gw_changes}" --parent "${head}" \
		--message-file "${gw_work}/message" --effort "${effort}") || exit $?
	result=$(printf '%s' "${made}" | jq -c '{commit, new: true, signed}')
fi
after=$(fingerprint) || gw_fail 'git could not read the checkout'
if [ "${before}" != "${after}" ]; then
	printf '%s: the checkout %s changed during the run; no snapshot printed: run again\n' "${gw_prog}" "${gw_repo}" >&2
	exit 5
fi
printf '%s\n' "${result}"
