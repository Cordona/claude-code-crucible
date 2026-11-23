#!/usr/bin/env sh
# Names the repository a folder belongs to and where its main checkout is.
# Reads only.
# shellcheck disable=SC2310,SC2312 # common_dir is in a condition for its status; a read inside a message only shortens the message
set -eu

usage() {
	cat <<'USAGE'
usage: sh repo-of.sh --dir FOLDER

Run by the domain's scripts; not for main to call.
Names the repository FOLDER belongs to: the top folder of git's common
directory, physical, which is its main checkout. A checkout and each of its
worktrees name the same repository.

Options:
  --dir FOLDER  a folder in a checkout or one of its worktrees, absolute
Writes:    nothing
Stdout:    one JSON line {repo, git_dir}: the main checkout's top folder and
           its .git folder
Exit:
  0  named
  2  refused, nothing changed; the reason is on stderr
  3  FOLDER is in no git repository
  4  git or jq not found
  5  FOLDER's repository is bare: it has no checkout
USAGE
}

readonly PROG='repo-of.sh'
# The C locale keeps the shell byte-wise. An inherited repository override
# would name another repository, and CDPATH would make cd print.
LC_ALL=C
export LC_ALL
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
	GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_PREFIX CDPATH

# Prints "repo-of.sh: $2" on stderr and exits $1.
say() {
	printf '%s: %s\n' "${PROG}" "$2" >&2
	exit "$1"
}

# Prints $1 with each control character as "?", so a value can't split a line.
printable() {
	printf '%s' "$1" | tr '[:cntrl:]' '?'
}

# Prints the physical path of the git common directory of folder $1; fails
# when $1 is in no git repository.
common_dir() {
	found=$(cd -- "$1" 2>/dev/null && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
	cd -P -- "${found}" 2>/dev/null && pwd -P
}

dir='' dir_given=no
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--dir)
			[ $# -ge 2 ] || say 2 '--dir needs a value'
			[ "${dir_given}" = no ] || say 2 '--dir given twice'
			dir=$2 dir_given=yes
			shift 2 ;;
		*) say 2 "unknown argument $(printable "$1"); try --help" ;;
	esac
done
[ "${dir_given}" = yes ] || say 2 '--dir missing'
case ${dir} in /*) ;; *) say 2 '--dir must be an absolute folder' ;; esac
command -v git >/dev/null 2>&1 || say 4 'git not found'
command -v jq >/dev/null 2>&1 || say 4 'jq not found'

shown=$(printable "${dir}")
common=$(common_dir "${dir}") || say 3 "${shown} is not in a git repository"
case ${common} in
	*/.git) ;;
	*) say 5 "${shown} belongs to no checkout (a bare repository)" ;;
esac
jq -nc --arg repo "${common%/.git}" --arg git_dir "${common}" '{repo: $repo, git_dir: $git_dir}'
