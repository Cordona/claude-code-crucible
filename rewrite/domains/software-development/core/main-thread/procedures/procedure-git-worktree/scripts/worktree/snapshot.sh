#!/usr/bin/env sh
# Turns a main checkout's uncommitted work into one commit object, so seats
# can start from what the human sees without the checkout being touched: a
# temp index built from HEAD takes every change git sees, and the commit is
# made from its tree with no ref, no index and no checkout file written. A
# fingerprint of the checkout taken before and after proves nothing moved.
set -eu
umask 077

readonly PROG='snapshot.sh'
readonly IDENT_NAME='crucible'
readonly IDENT_EMAIL='crucible@crucible.invalid'
readonly MESSAGE='crucible(snapshot): uncommitted changes'
# The C locale keeps the shell and its pattern classes byte-wise.
LC_ALL=C
export LC_ALL
# No git command here may refresh or write the checkout's real index.
GIT_OPTIONAL_LOCKS=0
GIT_TERMINAL_PROMPT=0
export GIT_OPTIONAL_LOCKS GIT_TERMINAL_PROMPT
# An inherited repository override would make git act outside --repo.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
	GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_PREFIX

usage() {
	cat <<EOF
usage: sh ${PROG} --repo DIR
       sh ${PROG} --help | -h

Makes one commit object of a main checkout's uncommitted work (staged,
unstaged and untracked; nothing git ignores), parent HEAD, message
"${MESSAGE}", author and committer
${IDENT_NAME} <${IDENT_EMAIL}>. Writes only git objects: no ref, no index,
no file of the checkout; runs no hook; signs nothing.

--repo DIR  absolute path of the main checkout's top folder; not a linked
            worktree, not bare, not sparse, with a HEAD commit and no merge,
            rebase, cherry-pick or revert under way

output, one stdout line:
  SNAPSHOT: <sha>   the new commit
  CLEAN: <sha>      nothing uncommitted: HEAD's sha, no object written

exit codes:
  0  printed
  2  wrong command line: a missing, repeated or unknown option, or a
     missing value
  3  --repo is not a main checkout fit for a snapshot; one stderr line per
     problem
  4  git is missing or failed
  5  the checkout changed during the run; no snapshot printed (run again)
EOF
}

warn() {
	printf '%s: %s\n' "${PROG}" "$1" >&2
}

die() {
	warn "$2"
	exit "$1"
}

usage_error() {
	warn "$1"
	printf "Try 'sh %s --help'.\n" "${PROG}" >&2
	exit 2
}

# Prints $1 with each control character as "?", so a path can't split a stderr line.
printable() {
	printf '%s' "$1" | tr '[:cntrl:]' '?'
}

parse_args() {
	repo=''
	while [ "$#" -gt 0 ]; do
		case $1 in
			-h | --help)
				usage
				exit 0
				;;
			--repo)
				[ -n "${2-}" ] || usage_error '--repo needs a value; expected --repo DIR'
				[ -z "${repo}" ] || usage_error '--repo given twice; expected one'
				repo=$2
				shift 2
				;;
			*)
				shown_option=$(printable "$1")
				usage_error "unknown option: ${shown_option}; expected --repo or --help"
				;;
		esac
	done
	[ -n "${repo}" ] || usage_error '--repo missing; expected --repo DIR'
}

# Refuses anything but a main checkout's top folder in a state a snapshot fits;
# sets git_dir and head.
check_repo() {
	shown_repo=$(printable "${repo}")
	case ${repo} in
		/*) ;;
		*) die 3 "--repo ${shown_repo} is not absolute; expected an absolute path" ;;
	esac
	[ -d "${repo}" ] || die 3 "--repo ${shown_repo} is not a folder; expected the main checkout's top folder"
	command -v git >/dev/null 2>&1 || die 4 'git not found; expected git 2.26+ on PATH'
	inside=$(git -C "${repo}" -c core.fsmonitor=false rev-parse --is-inside-work-tree 2>/dev/null) || inside=''
	[ "${inside}" = true ] || die 3 "--repo ${shown_repo} is not a git work tree; expected a main checkout, not bare"
	physical_repo=$(cd -P -- "${repo}" && pwd -P) || physical_repo=''
	top_folder=$(git -C "${repo}" -c core.fsmonitor=false rev-parse --show-toplevel 2>/dev/null) || top_folder=''
	shown_top_folder=$(printable "${top_folder}")
	[ -n "${top_folder}" ] && [ "${physical_repo}" = "${top_folder}" ] ||
		die 3 "--repo ${shown_repo} is not the checkout's top folder; expected ${shown_top_folder}"
	git_dir=$(git -C "${repo}" -c core.fsmonitor=false rev-parse --absolute-git-dir 2>/dev/null) || git_dir=''
	common_dir=$(git -C "${repo}" -c core.fsmonitor=false rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || common_dir=''
	[ -n "${git_dir}" ] && [ -n "${common_dir}" ] || die 4 "git could not name the git folders of ${shown_repo}; expected git 2.26+"
	[ "${git_dir}" = "${common_dir}" ] || die 3 "--repo ${shown_repo} is a linked worktree; expected the main checkout"
	check_state
}

check_state() {
	problems=0
	for state in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply; do
		[ ! -e "${git_dir}/${state}" ] || {
			warn "--repo ${shown_repo} has ${state} under way; expected no merge, rebase, cherry-pick or revert"
			problems=$((problems + 1))
		}
	done
	sparse=$(git -C "${repo}" -c core.fsmonitor=false config --type=bool core.sparseCheckout 2>/dev/null) || sparse=false
	[ "${sparse}" != true ] || {
		warn "--repo ${shown_repo} is a sparse checkout; expected a full checkout, as files outside it would read as deleted"
		problems=$((problems + 1))
	}
	head=$(git -C "${repo}" -c core.fsmonitor=false rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null) || head=''
	[ -n "${head}" ] || {
		warn "--repo ${shown_repo} has no HEAD commit; expected a branch or detached HEAD on a commit"
		problems=$((problems + 1))
	}
	[ "${problems}" -eq 0 ] || exit 3
}

# Sets fp to the checkout's state the snapshot must not move, and fp_head;
# exits 4 when git can't read a part. Every git call here reads only.
fingerprint() {
	fp_head=$(git -C "${repo}" -c core.fsmonitor=false rev-parse --verify --quiet HEAD) || fingerprint_failed
	fp_branch=$(git -C "${repo}" -c core.fsmonitor=false symbolic-ref -q HEAD) || fp_branch=detached
	index_file=$(git -C "${repo}" -c core.fsmonitor=false rev-parse --path-format=absolute --git-path index) ||
		fingerprint_failed
	fp_index=none
	[ ! -f "${index_file}" ] || fp_index=$(cksum <"${index_file}") || fingerprint_failed
	git -C "${repo}" -c core.fsmonitor=false status --porcelain=v1 -z --untracked-files=all >"${work_dir}/status" ||
		fingerprint_failed
	git -C "${repo}" -c core.fsmonitor=false for-each-ref --format='%(objectname) %(refname)' >"${work_dir}/refs" ||
		fingerprint_failed
	git -C "${repo}" -c core.fsmonitor=false stash list --format=%H >"${work_dir}/stash" || fingerprint_failed
	fp_status=$(cksum <"${work_dir}/status") || fingerprint_failed
	fp_refs=$(cksum <"${work_dir}/refs") || fingerprint_failed
	fp_stash=$(cksum <"${work_dir}/stash") || fingerprint_failed
	fp="head ${fp_head} branch ${fp_branch} index ${fp_index} status ${fp_status} refs ${fp_refs} stash ${fp_stash}"
}

fingerprint_failed() {
	die 4 "git could not read the state of ${shown_repo}"
}

# Sets tree: the tree of HEAD with every change git sees, built in a temp index.
build_tree() {
	temp_index="${work_dir}/index"
	GIT_INDEX_FILE=${temp_index} git -C "${repo}" -c core.fsmonitor=false read-tree "${head}" 2>"${work_dir}/stderr" ||
		git_failed "git read-tree ${head}"
	GIT_INDEX_FILE=${temp_index} git -C "${repo}" -c core.fsmonitor=false -c advice.addEmbeddedRepo=false \
		add -A >/dev/null 2>"${work_dir}/stderr" ||
		git_failed 'git add -A into the temp index'
	tree=$(GIT_INDEX_FILE=${temp_index} git -C "${repo}" -c core.fsmonitor=false write-tree 2>"${work_dir}/stderr") ||
		git_failed 'git write-tree'
	head_tree=$(git -C "${repo}" -c core.fsmonitor=false rev-parse --verify --quiet "${head}^{tree}") ||
		git_failed "git rev-parse ${head}^{tree}"
}

# Sets snapshot: the commit of tree on HEAD.
commit_tree() {
	snapshot=$(GIT_AUTHOR_NAME=${IDENT_NAME} GIT_AUTHOR_EMAIL=${IDENT_EMAIL} \
		GIT_COMMITTER_NAME=${IDENT_NAME} GIT_COMMITTER_EMAIL=${IDENT_EMAIL} \
		git -C "${repo}" -c core.fsmonitor=false -c core.hooksPath=/dev/null \
		commit-tree --no-gpg-sign "${tree}" -p "${head}" -m "${MESSAGE}" 2>"${work_dir}/stderr") || git_failed 'git commit-tree'
}

# Exits 4 naming step $1 and git's first stderr line.
git_failed() {
	first_line=$(head -n 1 "${work_dir}/stderr" 2>/dev/null) || first_line=''
	shown_line=$(printable "${first_line}")
	die 4 "$1 failed: ${shown_line}"
}

# shellcheck disable=SC2329 # invoked by the EXIT trap
clean_up() {
	[ -z "${work_dir}" ] || rm -rf -- "${work_dir}"
}

work_dir=''
trap clean_up EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

parse_args "$@"
check_repo
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/crucible-snapshot.XXXXXX") ||
	die 4 'mktemp could not create a work folder; expected a writable TMPDIR'
fingerprint
# The snapshot's parent is the HEAD the fingerprint saw, so a HEAD moved
# since check_repo can't slip past the comparison.
before=${fp} head=${fp_head}
build_tree
if [ "${tree}" = "${head_tree}" ]; then
	result="CLEAN: ${head}"
else
	commit_tree
	result="SNAPSHOT: ${snapshot}"
fi
fingerprint
[ "${before}" = "${fp}" ] ||
	die 5 "the checkout ${shown_repo} changed during the run; expected it untouched (no snapshot printed)"
printf '%s\n' "${result}"
