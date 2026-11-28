#!/usr/bin/env sh
# Cuts one tree of the effort from a base it resolves itself, sets it up,
# and records it as worktree.cut; a failed setup leaves no tree behind.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2310,SC2312 # each gw_ function exits on its own failure, and one in a condition is there for its status; a read inside a test or a message gives an empty or wrong value the test then refuses, or only shortens the message
set -eu
# The tree gets the caller's file modes, as a plain checkout would.
caller_umask=$(umask)
umask 077

usage() {
	cat <<'USAGE'
usage: sh worktree-cut.sh --effort FOLDER --repo DIR --name NAME --from BASE...

Cuts tree FOLDER/worktrees/NAME from BASE and copies in untracked dependencies.

Options:
  --effort FOLDER  the open effort's folder, absolute; outside the repo
  --repo DIR       any folder of the repo, absolute; cut from its main checkout
  --name NAME      lowercase, dash-joined; no live tree of the effort has it
  --from BASE      checkout (HEAD), snapshot (uncommitted work or HEAD), ref:REF
                   (a local commit), worktree:NAME (tip of this effort's live
                   tree in this repo); repeatable as worktree:NAME, tips merged
Requires:  snapshot, 2+ worktree:NAME: the effort's identity (git-identity);
           snapshot: HEAD exists; not sparse; no merge/rebase/cherry-pick/revert
Writes:    the tree, branch crucible/<FOLDER's name>/NAME, event worktree.cut
           {name, repo, path, branch, base, from, signed?}; signed only for a
           base the cut made (see Requires), false when it is unsigned
Stdout:    one path: the event's
Exit:
  0  cut and recorded
  2  refused, nothing changed; the reason is on stderr
  4  git, the setup or a neighbour failed; nothing is left behind
  5  the checkout changed during the snapshot, nothing cut: rerun
  6  the events lock stayed held, nothing is left behind: rerun
USAGE
}

gw_prog='worktree-cut.sh'
. "$(dirname -- "$0")/../lib/git-worktree.sh"
effort='' repo_in='' name='' froms=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--effort | --repo | --name | --from)
			[ $# -ge 2 ] || gw_refuse "$1 needs a value"
			case $1 in
				--effort) effort=$2 ;; --repo) repo_in=$2 ;; --name) name=$2 ;;
				--from) froms="${froms:+${froms} }$2" ;;
				*) ;;
			esac
			shift 2 ;;
		*) gw_refuse "unknown argument $1; try --help" ;;
	esac
done
gw_find_core "$0"
gw_find_commit
gw_check_effort "${effort}"
gw_require_open
gw_check_name "${name}"
gw_set_repo "${repo_in}"
[ -n "${froms}" ] || gw_refuse '--from needs a value: checkout, snapshot, worktree:NAME or ref:REF'
gw_make_work

live=$(sh "${gw_scripts}/internal/worktree-trees.sh" --effort "${gw_effort_given}" --name "${name}") || exit $?
[ "${live}" = '[]' ] \
	|| gw_refuse "the effort already has a live tree named ${name}; choose another name"
path="${gw_effort}/worktrees/${name}"
branch="crucible/${gw_effort_name}/${name}"
[ ! -e "${path}" ] && [ ! -L "${path}" ] || gw_refuse "${path} exists already; expected no folder there"
git check-ref-format "refs/heads/${branch}" || gw_refuse "${branch} is no branch name git takes"
! git -C "${gw_repo}" show-ref --verify --quiet "refs/heads/${branch}" \
	|| gw_refuse "the branch ${branch} exists already in ${gw_repo}; drop it or choose another name"
case ${path} in "${gw_repo}"/*) gw_refuse "the effort's folder lies inside ${gw_repo}; expected it outside" ;; *) ;; esac

# Sets base to the commit asked for.
resolve_base() {
	case ${froms} in
		*' '* | worktree:*) resolve_trees ;;
		checkout)
			base=$(git -C "${gw_repo}" rev-parse --verify --quiet 'HEAD^{commit}') || gw_refuse "the checkout ${gw_repo} has no HEAD commit"
			;;
		snapshot)
			made=$(sh "${gw_scripts}/main/worktree-snapshot.sh" --repo "${gw_repo}" --effort "${effort}") || exit $?
			base=$(printf '%s' "${made}" | jq -r '.commit')
			signed=$(printf '%s' "${made}" | jq -r '.signed')
			;;
		ref:*) base=$(gw_resolve_commit "${froms#ref:}" "${gw_repo}" '--from ref:') ;;
		*) gw_refuse "--from $(gw_printable "${froms}") is none of checkout, snapshot, worktree:NAME, ref:REF; only worktree:NAME repeats" ;;
	esac
}

# Sets base to the tip of each --from worktree:NAME tree, joined into one
# commit when there are several.
resolve_trees() {
	tips='' joined=''
	# shellcheck disable=SC2086 # the asked values hold no space, split on purpose
	for from in ${froms}; do
		case ${from} in worktree:*) ;; *) gw_refuse "--from ${from} is repeated with others; only worktree:NAME repeats" ;; esac
		source_name=${from#worktree:}
		case " ${joined} " in *" ${source_name} "*) gw_refuse "--from ${from} is given twice" ;; *) ;; esac
		joined="${joined:+${joined} }${source_name}"
		gw_check_name "${source_name}"
		gw_load_tree "${source_name}"
		[ "${gw_tree_repo}" = "${gw_repo}" ] || gw_refuse "tree ${source_name} is of ${gw_tree_repo}, not ${gw_repo}"
		tip=$(gw_branch_tip)
		[ -n "${tip}" ] || gw_refuse "tree ${source_name}'s branch ${gw_tree_branch} is gone"
		tips="${tips:+${tips} }${tip}"
	done
	case ${tips} in
		*' '*)
			gw_message base 'join the tips of the trees a tree is cut from' "${joined}"
			rc=0
			# shellcheck disable=SC2086 # the tips are full shas, split on purpose
			made=$(sh "${gw_commits_merge}" --repo "${gw_repo}" --commit ${tips} \
				--message-file "${gw_work}/message" --effort "${effort}" 2>"${gw_work}/merge-stderr") || rc=$?
			case ${rc} in
				0) cat "${gw_work}/merge-stderr" >&2 ;;
				3) gw_refuse "the tips of ${joined} conflict in $(printf '%s' "${made}" | jq -r '.conflicts | join(", ")'); nothing was cut" ;;
				*) cat "${gw_work}/merge-stderr" >&2; exit "${rc}" ;;
			esac
			base=$(printf '%s' "${made}" | jq -r '.commit')
			signed=$(printf '%s' "${made}" | jq -r '.signed')
			;;
		*) base=${tips} ;;
	esac
}

signed=''
resolve_base
started=no finished=no

# Removes the tree, its registration and its branch: none of them existed
# before this run, so each one there is this run's.
roll_back() {
	if ! git -C "${gw_repo}" worktree remove --force "${path}" >/dev/null 2>&1; then
		[ ! -d "${path}" ] || rm -rf -- "${path}" || printf '%s: could not remove %s; remove it by hand\n' "${gw_prog}" "${path}" >&2
		for entry_gitdir in "${gw_repo}"/.git/worktrees/*/gitdir; do
			[ -f "${entry_gitdir}" ] || continue
			[ "$(cat -- "${entry_gitdir}")" = "${path}/.git" ] || continue
			rm -rf -- "${entry_gitdir%/gitdir}"
		done
	fi
	! git -C "${gw_repo}" show-ref --verify --quiet "refs/heads/${branch}" \
		|| git -C "${gw_repo}" update-ref -d "refs/heads/${branch}" \
		|| printf '%s: could not delete the branch %s; delete it with git branch -D\n' "${gw_prog}" "${branch}" >&2
	printf '%s: removed the tree %s, its registration and its branch again\n' "${gw_prog}" "${name}" >&2
}

# Rolls back a cut stopped before its event was written.
on_exit() {
	if [ "${started}" = yes ] && [ "${finished}" = no ]; then roll_back; fi
	gw_clean_up
}
trap on_exit EXIT

fail_back() {
	printf '%s: %s\n' "${gw_prog}" "$1" >&2
	exit "${2:-4}"
}

mkdir -p -- "${gw_effort}/worktrees" || gw_fail "could not make ${gw_effort}/worktrees"
started=yes
(umask "${caller_umask}" && git -C "${gw_repo}" -c core.hooksPath=/dev/null -c core.fsmonitor=false \
	worktree add --no-track --quiet -b "${branch}" "${path}" "${base}" >&2) \
	|| fail_back "git worktree add failed for ${path}"
[ "$(git -C "${path}" symbolic-ref -q HEAD 2>/dev/null || :)" = "refs/heads/${branch}" ] \
	|| fail_back "the new tree's HEAD is not on ${branch}"
[ "$(git -C "${path}" rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null || :)" = "${base}" ] \
	|| fail_back "the new tree's HEAD is not the base ${base}"
[ "$(gw_uncommitted "${path}")" -eq 0 ] || fail_back 'the new tree is not clean'

setup_rc=0
(umask "${caller_umask}" && sh "${gw_scripts}/internal/worktree-setup.sh" --from "${gw_repo}" --to "${path}") >&2 || setup_rc=$?
[ "${setup_rc}" -eq 0 ] || fail_back "worktree-setup.sh failed (exit ${setup_rc})"

jq -n --arg name "${name}" --arg repo "${gw_repo}" --arg path "${path}" --arg branch "${branch}" \
	--arg base "${base}" --arg from "${froms}" --arg signed "${signed}" \
	'{name: $name, repo: $repo, path: $path, branch: $branch, base: $base, from: $from}
	 + (if $signed == "" then {} else {signed: ($signed == "true")} end)' >"${gw_work}/body"
write_rc=0
event=$(gw_write worktree.cut "${gw_work}/body") || write_rc=$?
[ "${write_rc}" -eq 0 ] || fail_back 'worktree.cut was not written' "${write_rc}"
finished=yes
printf '%s\n' "${event}"
