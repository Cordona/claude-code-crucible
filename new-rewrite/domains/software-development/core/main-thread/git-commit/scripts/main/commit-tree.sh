#!/usr/bin/env sh
# Commits every change in one tree on its crucible/ branch, signed as the
# effort's identity for the repository.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2310,SC2312 # tree_git and the git reads in tests are one git command each: a failure gives an empty or wrong value, which the check then refuses
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh commit-tree.sh --worktree DIR --message-file FILE --effort FOLDER
                        [--unsigned]

Commits every change in an effort's worktree (untracked too, not ignored) on
its branch as the effort's identity: signed, or unsigned when signing fails
or takes over 10 s, or with --unsigned. Also finishes a resolved merge
(worktree-catch-up.sh's "conflict"), even with no change.

Options:
  --worktree DIR       a linked worktree's top folder, absolute, on a branch
                       under crucible/<effort folder name>/
  --message-file FILE  the message (commit-message.sh), absolute; an Effort
                       trailer is added when missing, refused when another's
  --effort FOLDER      the effort's folder, absolute
  --unsigned           no signing attempt: a working commit, never landed
Requires:  the effort's identity set; no pick, revert or rebase under way;
           no conflict markers left in a merge
Writes:    the commit on the tree's branch; never git config, no git hooks
Stdout:    {"commit": SHA, "signed": true|false}, one JSON line
Exit:
  0  committed
  2  refused, nothing changed; the reason is on stderr
  3  nothing to commit (never in a merge)
  4  staging, the commit or its checks failed; a commit made stays
USAGE
}

gc_prog='commit-tree.sh'
. "$(dirname -- "$0")/../lib/git-commit.sh"

fail() {
	printf '%s: %s\n' "${gc_prog}" "$1" >&2
	exit 4
}

# git in the tree, no fsmonitor, every pathspec literal.
tree_git() {
	git -C "${worktree}" -c core.fsmonitor=false --literal-pathspecs "$@"
}

# Refuses anything but a linked worktree's top folder with HEAD at a commit
# on a branch under crucible/<effort folder name>/; sets git_dir, branch and
# old_head.
check_worktree() {
	case ${worktree} in /*) ;; *) gc_refuse '--worktree must be an absolute folder' ;; esac
	[ -d "${worktree}" ] || gc_refuse "--worktree ${worktree} is not a folder"
	[ "$(tree_git rev-parse --is-inside-work-tree 2>/dev/null || :)" = true ] ||
		gc_refuse "--worktree ${worktree} is not a git worktree"
	physical=$(cd -P -- "${worktree}" && pwd -P)
	[ "$(tree_git rev-parse --show-toplevel)" = "${physical}" ] ||
		gc_refuse "--worktree ${worktree} is not the worktree's top folder"
	git_dir=$(tree_git rev-parse --absolute-git-dir)
	[ "${git_dir}" != "$(tree_git rev-parse --path-format=absolute --git-common-dir)" ] ||
		gc_refuse "--worktree ${worktree} is a main checkout; expected a linked worktree"
	head_ref=$(tree_git symbolic-ref -q HEAD) || gc_refuse "--worktree ${worktree} has a detached HEAD"
	branch=${head_ref#refs/heads/}
	case ${branch} in
		"crucible/${gc_effort_name}/"?*) ;;
		*) gc_refuse "--worktree ${worktree} has HEAD on ${branch}; expected a branch under crucible/${gc_effort_name}/" ;;
	esac
	old_head=$(tree_git rev-parse --verify -q 'HEAD^{commit}') || gc_refuse "--worktree ${worktree} has no HEAD commit"
}

# Refuses a pick, revert or rebase under way, and a merge that isn't one
# commit or still holds a conflict marker; sets merge_head, empty when no
# merge is under way.
check_operation() {
	for state in CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply; do
		[ ! -e "${git_dir}/${state}" ] || gc_refuse "--worktree ${worktree} has ${state} under way; expected no pick, revert or rebase"
	done
	merge_head=''
	[ -e "${git_dir}/MERGE_HEAD" ] || return 0
	if [ "$(wc -l <"${git_dir}/MERGE_HEAD")" -ne 1 ] ||
		! merge_head=$(tree_git rev-parse --verify -q 'MERGE_HEAD^{commit}'); then
		gc_refuse "--worktree ${worktree} has a MERGE_HEAD that is not one commit"
	fi
	check_markers
}

# git diff --check exits 2 for any finding, whitespace included; only
# leftover conflict markers count.
check_markers() {
	check_rc=0
	tree_git diff HEAD --check >"${gc_work}/check" 2>/dev/null || check_rc=$?
	[ "${check_rc}" -le 2 ] || gc_refuse "--worktree ${worktree}: git diff --check could not read the merge's changes"
	marked=$(sed -n 's/^\(.*\):[0-9][0-9]*: leftover conflict marker$/\1/p' "${gc_work}/check" | sort -u | tr '\n' ' ')
	[ -z "${marked}" ] || gc_refuse "the merge of ${merge_head} still has conflict markers in: ${marked% }"
}

# Stages every change; exits 3 when, outside a merge, nothing is staged.
stage_changes() {
	tree_git add -A >&2 || fail_restored 'git add failed'
	[ -z "${merge_head}" ] || return 0
	if tree_git diff --cached --quiet; then
		printf '%s: nothing to commit in %s\n' "${gc_prog}" "${worktree}" >&2
		exit 3
	fi
}

# Unstages again and exits 4; in a merge the index is left, since a reset
# would end the merge.
fail_restored() {
	[ -n "${merge_head}" ] || tree_git reset -q >/dev/null 2>&1 || :
	fail "$1"
}

# Commits signed, as the identity, with no hook, the message verbatim; a
# signed attempt that failed with HEAD unmoved is made again unsigned. With
# --unsigned there is no signed attempt.
commit_staged() {
	if [ -n "${unsigned}" ]; then
		signed=false
		commit_unsigned
		return 0
	fi
	gc_run_signed "${worktree}" -c core.hooksPath=/dev/null commit -S -q --no-verify --cleanup=verbatim -F "${gc_work}/message"
	signed=true
	[ "${gc_sign_rc}" -ne 0 ] || return 0
	head_unmoved
	signed=false
	commit_unsigned
	gc_say_unsigned
}

# Commits unsigned, as the identity, with no hook, the message verbatim.
commit_unsigned() {
	gc_identity_git "${worktree}" -c core.hooksPath=/dev/null commit --no-gpg-sign -q --no-verify --cleanup=verbatim \
		-F "${gc_work}/message" </dev/null >&2 2>"${gc_work}/commit-stderr" || {
		head_unmoved
		fail_restored "git commit failed: $(head -n 1 "${gc_work}/commit-stderr")"
	}
}

# A failed commit that still moved HEAD made something nobody asked for.
head_unmoved() {
	[ "$(tree_git rev-parse --verify -q HEAD || :)" = "${old_head}" ] ||
		fail 'git commit failed but HEAD moved'
}

# Checks the new commit: on the branch, the right parents, the message and
# the signature as made, and nothing left uncommitted.
verify_commit() {
	new_head=$(tree_git rev-parse --verify -q HEAD) || fail 'HEAD can not be read after the commit'
	[ "${new_head}" != "${old_head}" ] || fail 'HEAD did not change; expected a new commit'
	[ "$(tree_git rev-parse --verify -q "refs/heads/${branch}")" = "${new_head}" ] ||
		fail "the branch ${branch} is not at the new commit"
	expected_parents=${old_head}
	[ -z "${merge_head}" ] || expected_parents="${old_head} ${merge_head}"
	[ "$(tree_git show -s --no-show-signature --format=%P "${new_head}")" = "${expected_parents}" ] ||
		fail "the new commit's parents are not ${expected_parents}"
	[ ! -e "${git_dir}/MERGE_HEAD" ] || fail 'MERGE_HEAD is still there after the commit'
	tree_git cat-file commit "${new_head}" | sed '1,/^$/d' | cmp -s - "${gc_work}/message" ||
		fail 'the commit message differs from the one asked for'
	[ "$(gc_carries_signature "${worktree}" "${new_head}")" = "${signed}" ] ||
		fail "the new commit's signature is not what was made (signed: ${signed})"
	[ -z "$(tree_git status --porcelain --untracked-files=all --ignore-submodules=none)" ] ||
		fail 'the tree still shows a change after the commit'
}

worktree='' message_file='' effort='' unsigned=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--unsigned) unsigned=1; shift ;;
		--worktree | --message-file | --effort)
			[ $# -ge 2 ] && [ -n "$2" ] || gc_refuse "$1 needs a value"
			case $1 in --worktree) worktree=$2 ;; --message-file) message_file=$2 ;; --effort) effort=$2 ;; *) ;; esac
			shift 2 ;;
		*) gc_refuse "unknown argument $1; try --help" ;;
	esac
done
[ -n "${worktree}" ] || gc_refuse '--worktree missing'
[ -n "${message_file}" ] || gc_refuse '--message-file missing'
[ -n "${effort}" ] || gc_refuse '--effort missing'
command -v git >/dev/null 2>&1 || gc_refuse 'git not found'
command -v jq >/dev/null 2>&1 || gc_refuse 'jq not found'
gc_find_neighbours "$0"
gc_check_effort "${effort}"
gc_make_work
check_worktree
gc_read_identity "${effort}" "${worktree}"
gc_effort_message "${message_file}" "${worktree}"
check_operation
stage_changes
commit_staged
verify_commit
jq -nc --arg commit "${new_head}" --argjson signed "${signed}" '{commit: $commit, signed: $signed}'
