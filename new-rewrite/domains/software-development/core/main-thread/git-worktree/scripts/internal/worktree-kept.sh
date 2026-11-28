#!/usr/bin/env sh
# Lists the refs a tree's work is kept under, and names the next free one.
# Reads only.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2310,SC2312 # each gw_ function exits on its own failure, and one in a condition is there for its status; a read inside a message only shortens the message
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh worktree-kept.sh --effort FOLDER --name NAME [--next KIND]

Run by worktree-move.sh, worktree-discard.sh and worktree-drop.sh; not for
main to call.

Lists the refs that hold a live tree's work kept by earlier moves and
discards.

Options:
  --effort FOLDER  the effort's folder, absolute
  --name NAME      a live tree of the effort
  --next KIND      also name the next free ref of KIND, moved or discarded
Writes:    nothing
Stdout:    one JSON line {kept: [REF...], next?: REF}; kept holds both kinds,
           [] when none; REF is refs/crucible/KIND/<effort folder name>/NAME/N
Exit:
  0  listed
  2  refused, nothing changed; the reason is on stderr
  4  reading the events or refs failed, or git or jq is missing: fix, rerun
USAGE
}

gw_prog='worktree-kept.sh'
. "$(dirname -- "$0")/../lib/git-worktree.sh"
effort='' name='' next=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--effort | --name | --next)
			[ $# -ge 2 ] || gw_refuse "$1 needs a value"
			case $1 in --effort) effort=$2 ;; --name) name=$2 ;; --next) next=$2 ;; *) ;; esac
			shift 2 ;;
		*) gw_refuse "unknown argument $1; try --help" ;;
	esac
done
case ${next} in
	'' | moved | discarded) ;;
	*) gw_refuse "--next $(gw_printable "${next}") is neither moved nor discarded" ;;
esac
gw_find_core "$0"
gw_check_effort "${effort}"
gw_check_name "${name}"
gw_load_tree "${name}"

gw_make_work
git -C "${gw_tree_repo}" for-each-ref --format='%(refname)' \
	"refs/crucible/moved/${gw_effort_name}/${name}/" "refs/crucible/discarded/${gw_effort_name}/${name}/" \
	>"${gw_work}/kept" || gw_fail "git for-each-ref failed in ${gw_tree_repo}"
next_ref=''
if [ -n "${next}" ]; then
	prefix="refs/crucible/${next}/${gw_effort_name}/${name}"
	highest=$(sed -n "s|^${prefix}/\([0-9][0-9]*\)$|\1|p" "${gw_work}/kept" | sort -n | tail -n 1)
	next_ref="${prefix}/$((${highest:-0} + 1))"
fi
jq -Rnc --arg next "${next_ref}" '{kept: [inputs]} + (if $next == "" then {} else {next: $next} end)' "${gw_work}/kept"
