#!/usr/bin/env sh
# Writes a tree's work as a reviewer reads it to a diff file and prints the
# file's path. Reads git only.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2310,SC2312 # each gw_ function exits on its own failure, and one in a condition is there for its status; a read inside a test or a message gives an empty or wrong value the test then refuses, or only shortens the message
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh worktree-diff.sh --effort FOLDER --name NAME [--base COMMIT]

Writes a live tree's committed work, base to branch tip, to one file for a
reviewer: sections ## Commits (with messages), ## Changed files and ## Diff.
Uncommitted changes are left out: commit first to include them.

Options:
  --effort FOLDER  the effort's folder, absolute
  --name NAME      a live tree of the effort
  --base COMMIT    any commit of the tree's repository; default the target
                   of the tree's latest move, else the commit it was cut at
Requires:  the tree's branch still exists
Writes:    <effort>/diffs/NAME-<base12>-<tip12>.patch, replacing one of that
           name; no repository change, no event
Stdout:    one line, the file's absolute path
Exit:
  0  written
  2  refused, nothing changed; the reason is on stderr
  4  git or jq missing, git or core's reader failed, or the file was not
     written
USAGE
}

gw_prog='worktree-diff.sh'
. "$(dirname -- "$0")/../lib/git-worktree.sh"
effort='' name='' base_in=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--effort | --name | --base)
			[ $# -ge 2 ] || gw_refuse "$1 needs a value"
			case $1 in --effort) effort=$2 ;; --name) name=$2 ;; --base) base_in=$2 ;; *) ;; esac
			shift 2 ;;
		*) gw_refuse "unknown argument $1; try --help" ;;
	esac
done
gw_find_core "$0"
gw_check_effort "${effort}"
gw_check_name "${name}"
gw_make_work
gw_load_tree "${name}"
repo=${gw_tree_repo}
tip=$(gw_branch_tip)
[ -n "${tip}" ] || gw_refuse "tree ${name}'s branch ${gw_tree_branch} is gone"
base=${gw_tree_base}
[ -z "${base_in}" ] || base=$(gw_resolve_commit "${base_in}" "${repo}" --base)

diffs="${gw_effort}/diffs"
mkdir -p -- "${diffs}" || gw_fail "could not make ${diffs}"
file="${diffs}/${name}-$(git -C "${repo}" rev-parse --short=12 "${base}")-$(git -C "${repo}" rev-parse --short=12 "${tip}").patch"
{
	printf '# The work of tree %s: %s...%s\n\n## Commits\n\n' "${name}" "${base}" "${tip}"
	git -C "${repo}" log --no-color --format='commit %H%n%n%B' "${base}..${tip}"
	printf '\n## Changed files\n\n'
	git -C "${repo}" diff --no-color --no-ext-diff --name-status "${base}...${tip}"
	printf '\n## Diff\n\n'
	git -C "${repo}" diff --no-color --no-ext-diff "${base}...${tip}"
} >"${file}.tmp" || { rm -f -- "${file}.tmp"; gw_fail "could not write ${file}"; }
mv -f -- "${file}.tmp" "${file}" || gw_fail "could not write ${file}"
printf '%s\n' "${file}"
