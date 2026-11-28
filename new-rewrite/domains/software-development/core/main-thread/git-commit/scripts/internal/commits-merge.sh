#!/usr/bin/env sh
# Merges several commits into one signed commit object with git merge-tree;
# writes git objects only.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2310,SC2312 # gc_repo_git and the git reads in tests are one git command each: a failure gives an empty or wrong value, which the check then refuses
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh commits-merge.sh --repo DIR --commit COMMIT [--commit COMMIT]...
                           --message-file FILE --effort FOLDER

Run by the git-worktree and git-mount scripts; not for main to call.
Merges commits of one repository into one merge commit made as the effort's
identity, parents in the given order, after dropping repeats and ancestors.

Options:
  --repo DIR           a folder in the repository or a worktree, absolute
  --commit COMMIT      commits, branches or tags, one or more per --commit;
                       repeatable; two or more in all
  --message-file FILE  the message, absolute, used as is; its Effort trailer
                       must name this effort, and is added when absent
  --effort FOLDER      the effort's folder, absolute
Requires:  an identity for the repository set through git-identity
Writes:    git objects only; no ref, index, worktree or git config change
Stdout:    one JSON line {commit, new, signed}; new false: a given commit
           holds the others and is returned; signed: it carries a signature
Exit:
  0  merged, or one commit returned
  2  refused, nothing written; the reason is on stderr
  3  the commits conflict; stdout is {conflicts: [PATH...]}
  4  git or jq failed; the reason is on stderr
USAGE
}

gc_prog='commits-merge.sh'
. "$(dirname -- "$0")/../lib/git-commit.sh"

fail() {
	printf '%s: %s\n' "${gc_prog}" "$1" >&2
	exit 4
}

# Appends each given commit's full sha to gc_work/given, refusing one that
# is no commit in the repository.
add_commit() {
	case $1 in -*) gc_refuse "--commit $1 is not a commit" ;; *) ;; esac
	full=$(gc_repo_git rev-parse --verify --quiet --end-of-options "$1^{commit}" 2>/dev/null) ||
		gc_refuse "--commit $1 is not a commit in ${repo}"
	printf '%s\n' "${full}" >>"${gc_work}/given"
}

# Writes gc_work/kept: the given commits, repeats dropped, without any that
# another given commit holds, in the given order.
keep_tips() {
	awk '!seen[$0]++' "${gc_work}/given" >"${gc_work}/distinct"
	: >"${gc_work}/kept"
	while IFS= read -r candidate; do
		held=false
		while IFS= read -r other; do
			[ "${other}" != "${candidate}" ] || continue
			ancestor_rc=0
			gc_repo_git merge-base --is-ancestor "${candidate}" "${other}" || ancestor_rc=$?
			case ${ancestor_rc} in
				0) held=true; break ;;
				1) ;;
				*) fail 'git merge-base --is-ancestor failed' ;;
			esac
		done <"${gc_work}/distinct"
		[ "${held}" = true ] || printf '%s\n' "${candidate}" >>"${gc_work}/kept"
	done <"${gc_work}/distinct"
}

# Folds the kept commits left into merged_tree; exits 3 naming the paths of
# a step that conflicts.
fold_tips() {
	previous='' last_tip=''
	while IFS= read -r tip; do
		if [ -z "${previous}" ]; then
			previous=${tip}
			continue
		fi
		if [ -n "${last_tip}" ]; then
			previous=$(gc_identity_git "${repo}" commit-tree "${merged_tree}" -p "${previous}" -p "${last_tip}" -m 'crucible(merge): fold step' \
				</dev/null 2>"${gc_work}/stderr") || fail "git commit-tree failed: $(head -n 1 "${gc_work}/stderr")"
		fi
		merge_step "${previous}" "${tip}"
		last_tip=${tip}
	done <"${gc_work}/kept"
}

# Merges commits $1 and $2 into merged_tree, or exits 3 with the conflicts.
merge_step() {
	step_rc=0
	gc_repo_git merge-tree --write-tree -z --name-only --no-messages "$1" "$2" >"${gc_work}/step" 2>"${gc_work}/stderr" || step_rc=$?
	[ "${step_rc}" -le 1 ] || fail "git merge-tree failed: $(head -n 1 "${gc_work}/stderr")"
	# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
	jq -Rsc 'split("\u0000") | map(select(. != "")) | {tree: .[0], conflicts: .[1:]}' "${gc_work}/step" >"${gc_work}/step.json" ||
		fail 'jq could not read the git merge-tree output'
	merged_tree=$(jq -r '.tree // ""' "${gc_work}/step.json")
	[ "${step_rc}" -eq 1 ] || return 0
	jq -c '{conflicts: (.conflicts | unique)}' "${gc_work}/step.json"
	printf '%s: the commits conflict in: %s\n' "${gc_prog}" \
		"$(jq -j '.conflicts | unique | join(" ")' "${gc_work}/step.json" | tr '[:cntrl:]' '?')" >&2
	exit 3
}

# Writes the merge commit of merged_tree with every kept commit as a
# parent; signed, else, when signing fails, unsigned.
write_merge() {
	set --
	while IFS= read -r tip; do
		set -- "$@" -p "${tip}"
	done <"${gc_work}/kept"
	gc_run_signed "${repo}" commit-tree -S "${merged_tree}" "$@" -F "${gc_work}/message"
	signed=true
	if [ "${gc_sign_rc}" -eq 0 ] && IFS= read -r made <"${gc_work}/signed-out" && [ -n "${made}" ]; then
		return 0
	fi
	signed=false
	made=$(gc_identity_git "${repo}" commit-tree "${merged_tree}" "$@" -F "${gc_work}/message" </dev/null 2>"${gc_work}/stderr") ||
		fail "git commit-tree failed: $(head -n 1 "${gc_work}/stderr")"
	gc_say_unsigned
}

repo='' message_file='' effort='' commit_count=0
gc_make_work
: >"${gc_work}/args"
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--repo | --message-file | --effort)
			[ $# -ge 2 ] && [ -n "$2" ] || gc_refuse "$1 needs a value"
			case $1 in --repo) repo=$2 ;; --message-file) message_file=$2 ;; --effort) effort=$2 ;; *) ;; esac
			shift 2 ;;
		--commit)
			shift
			[ $# -ge 1 ] && [ -n "$1" ] && [ "${1#--}" = "$1" ] || gc_refuse '--commit needs a value'
			while [ $# -ge 1 ] && [ "${1#--}" = "$1" ]; do
				printf '%s\n' "$1" >>"${gc_work}/args"
				commit_count=$((commit_count + 1))
				shift
			done ;;
		*) gc_refuse "unknown argument $1; try --help" ;;
	esac
done
[ -n "${repo}" ] || gc_refuse '--repo missing'
[ -n "${message_file}" ] || gc_refuse '--message-file missing'
[ -n "${effort}" ] || gc_refuse '--effort missing'
[ "${commit_count}" -ge 2 ] || gc_refuse "--commit given ${commit_count} commit(s); expected at least two"
command -v git >/dev/null 2>&1 || gc_refuse 'git not found'
command -v jq >/dev/null 2>&1 || gc_refuse 'jq not found'
gc_find_neighbours "$0"
gc_check_repo "${repo}"
gc_check_effort "${effort}"
: >"${gc_work}/given"
while IFS= read -r given; do add_commit "${given}"; done <"${gc_work}/args"
gc_read_identity "${effort}" "${repo}"
gc_effort_message "${message_file}" "${repo}"
keep_tips
if [ "$(wc -l <"${gc_work}/kept")" -eq 1 ]; then
	IFS= read -r made <"${gc_work}/kept"
	jq -nc --arg commit "${made}" --argjson signed "$(gc_carries_signature "${repo}" "${made}")" \
		'{commit: $commit, new: false, signed: $signed}'
	exit 0
fi
fold_tips
write_merge
jq -nc --arg commit "${made}" --argjson signed "${signed}" '{commit: $commit, new: true, signed: $signed}'
