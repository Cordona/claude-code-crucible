#!/usr/bin/env sh
# Says whether the human's checkout holds a mount and how it stands. Reads
# only.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2310,SC2312 # each gm_ function exits on its own failure, and one in a condition is there for its status; a read inside a message only shortens the message
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh mount-status.sh --repo DIR [--effort FOLDER]

Says whether the repository's main checkout holds a mount and how it stands.
Use it before offering a remount or an undo.

Options:
  --repo DIR       any folder of the repository, absolute
  --effort FOLDER  an effort folder, absolute; adds ours: whether this
                   effort made the mount
Writes:    nothing
Stdout:    one JSON line: {"mounted":false} when nothing is mounted, else
           {mounted: true, effort, trees: [{name, tip, now, moved}], moved,
           head_moved, finished, paths, edited, ours?}: effort is the folder
           of the effort that made the mount; tip is the tree's commit as
           mounted, now its branch tip, null once gone (then moved is false);
           finished is HEAD moved and holding every mounted path (the human
           committed the mount: an undo only forgets it); paths counts the
           mounted paths; edited lists those changed or gone
Exit:
  0  printed, mounted or not
  2  refused, nothing changed; the reason is on stderr
  4  git failed, or git or jq is missing
USAGE
}

gm_prog='mount-status.sh'
. "$(dirname -- "$0")/../lib/mount.sh"
repo_in='' effort=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--repo | --effort)
			[ $# -ge 2 ] || gm_refuse "$1 needs a value"
			case $1 in --repo) repo_in=$2 ;; --effort) effort=$2 ;; *) ;; esac
			shift 2 ;;
		*) gm_refuse "unknown argument $1; try --help" ;;
	esac
done
gm_find_self "$0"
[ -z "${effort}" ] || gm_check_effort "${effort}"
gm_set_repo "${repo_in}"
gm_make_work
rc=0
sh "${gm_scripts}/internal/mount-record.sh" --repo "${gm_repo}" >"${gm_work}/record" 2>"${gm_work}/stderr" || rc=$?
case ${rc} in
	0) ;;
	5) printf '{"mounted":false}\n'; exit 0 ;;
	*) cat "${gm_work}/stderr" >&2; exit "${rc}" ;;
esac
sh "${gm_scripts}/internal/mount-paths.sh" --repo "${gm_repo}" >"${gm_work}/now" || exit $?
jq -r '.trees[].branch' "${gm_work}/record" | while IFS= read -r branch; do
	git -C "${gm_repo}" rev-parse --verify --quiet "refs/heads/${branch}^{commit}" 2>/dev/null || echo
done >"${gm_work}/tips"
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
jq -c --slurpfile now "${gm_work}/now" --rawfile tips "${gm_work}/tips" --arg ours "${gm_effort-}" '
	($tips | rtrimstr("\n") | split("\n")) as $t
	| [.trees | to_entries[] | .value + {now: (if $t[.key] == "" then null else $t[.key] end)}
		| {name, tip, now, moved: (.now != null and .now != .tip)}] as $trees
	| {mounted: true, effort, trees: $trees, moved: any($trees[]; .moved),
	   head_moved: $now[0].head_moved, finished: $now[0].finished, paths: (.paths | length),
	   edited: [$now[0].paths[] | select(.now == "edited" or .now == "gone") | .path]}
	+ (if $ours == "" then {} else {ours: (.effort == $ours)} end)' "${gm_work}/record"
