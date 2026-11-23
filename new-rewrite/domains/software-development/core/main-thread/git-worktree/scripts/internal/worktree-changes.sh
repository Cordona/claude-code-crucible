#!/usr/bin/env sh
# Writes a tree object of a commit plus every change in a worktree folder,
# through a temp index; the folder's own index, files and refs stay as they
# were.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2310,SC2312 # each gw_ function exits on its own failure, and one in a condition is there for its status; a read inside a message only shortens the message
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh worktree-changes.sh --dir FOLDER --head COMMIT

Run by worktree-snapshot.sh and worktree-discard.sh; not for main to call.

Writes a git tree: COMMIT's tree with the work tree's files laid over it as
they are on disk (edits, deletions, untracked files that are not ignored).

Options:
  --dir FOLDER   absolute; any folder in the work tree; the whole tree is taken
  --head COMMIT  the commit the files are laid on
Writes:    git objects only; no index, file or ref
Stdout:    one JSON line {tree, head_tree}, full shas; head_tree is
           COMMIT's tree; equal when nothing changed
Exit:
  0  written
  2  refused, nothing changed; the reason is on stderr
  4  git failed, or git or jq is missing: fix and rerun
USAGE
}

gw_prog='worktree-changes.sh'
. "$(dirname -- "$0")/../lib/git-worktree.sh"
dir='' head_in=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--dir | --head)
			[ $# -ge 2 ] || gw_refuse "$1 needs a value"
			case $1 in --dir) dir=$2 ;; --head) head_in=$2 ;; *) ;; esac
			shift 2 ;;
		*) gw_refuse "unknown argument $1; try --help" ;;
	esac
done
case ${dir} in
	'') gw_refuse '--dir needs a value' ;;
	/*) ;;
	*) gw_refuse '--dir must be an absolute folder' ;;
esac
command -v git >/dev/null 2>&1 || gw_fail 'git not found'
command -v jq >/dev/null 2>&1 || gw_fail 'jq not found'
git -C "${dir}" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
	|| gw_refuse "--dir $(gw_printable "${dir}") is not in a git work tree"
head=$(gw_resolve_commit "${head_in}" "${dir}" --head)
gw_make_work

index="${gw_work}/index"
GIT_INDEX_FILE=${index} git -C "${dir}" -c core.fsmonitor=false read-tree "${head}" 2>"${gw_work}/stderr" \
	|| gw_fail "git read-tree ${head} failed: $(head -n 1 "${gw_work}/stderr")"
GIT_INDEX_FILE=${index} git -C "${dir}" -c core.fsmonitor=false -c advice.addEmbeddedRepo=false \
	add -A >/dev/null 2>"${gw_work}/stderr" \
	|| gw_fail "git add -A into a temp index failed: $(head -n 1 "${gw_work}/stderr")"
tree=$(GIT_INDEX_FILE=${index} git -C "${dir}" -c core.fsmonitor=false write-tree 2>"${gw_work}/stderr") \
	|| gw_fail "git write-tree failed: $(head -n 1 "${gw_work}/stderr")"
head_tree=$(git -C "${dir}" rev-parse --verify --quiet "${head}^{tree}") || gw_fail "git rev-parse ${head}^{tree} failed"
jq -nc --arg t "${tree}" --arg h "${head_tree}" '{tree: $t, head_tree: $h}'
