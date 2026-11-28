#!/usr/bin/env sh
# Says how each mounted path stands in the checkout now. Reads only.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2310,SC2312 # each gm_ function exits on its own failure, and one in a condition is there for its status; a read inside a message only shortens the message
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh mount-paths.sh --repo FOLDER

Run by mount-status.sh, mount-apply.sh, mount-undo.sh and open-work.sh; not
for main to call. Says how each path of the mount in place stands now.

Options:
  --repo FOLDER  any folder of the repository or its worktrees, absolute
Writes:    nothing
Stdout:    one JSON line {head, head_moved, finished, paths: [{path, now}]}:
           head is HEAD's sha or null; head_moved is true when HEAD is not
           the mount's; finished is head_moved and every path committed; now
           is committed (HEAD moved and the path matches it), mounted (as the
           mount left it), gone (absent) or edited (anything else)
Exit:
  0  printed
  2  refused, nothing changed; the reason is on stderr
  4  git failed or jq is missing
  5  nothing is mounted
USAGE
}

gm_prog='mount-paths.sh'
. "$(dirname -- "$0")/../lib/mount.sh"
repo_in=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--repo) [ $# -ge 2 ] || gm_refuse '--repo needs a value'; repo_in=$2; shift 2 ;;
		*) gm_refuse "unknown argument $1; try --help" ;;
	esac
done
gm_find_self "$0"
gm_set_repo "${repo_in}"
gm_make_work
rc=0
sh "${gm_scripts}/internal/mount-record.sh" --repo "${gm_repo}" >"${gm_work}/record" || rc=$?
[ "${rc}" -eq 0 ] || exit "${rc}"
jq -r '.paths[].path' "${gm_work}/record" >"${gm_work}/paths"
sh "${gm_scripts}/internal/mount-states.sh" --repo "${gm_repo}" --paths "${gm_work}/paths" >"${gm_work}/states" || exit $?
head=$(git -C "${gm_repo}" rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null) || head=''
recorded_head=$(jq -r '.head' "${gm_work}/record")
: >"${gm_work}/head-tree"
if [ -n "${head}" ] && [ "${head}" != "${recorded_head}" ]; then
	tr '\n' '\000' <"${gm_work}/paths" \
		| GIT_LITERAL_PATHSPECS=1 xargs -0 git -C "${gm_repo}" ls-tree -r -z --full-tree "${head}" -- \
			>"${gm_work}/head-tree" 2>"${gm_work}/stderr" || gm_git_failed "git ls-tree of HEAD ${head}"
fi
# Each ls-tree entry is "<mode> <type> <sha><TAB><path>"; a path HEAD's tree
# lacks is absent there.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
jq -Rsc --slurpfile record "${gm_work}/record" --slurpfile states "${gm_work}/states" --arg head "${head}" '
	(split("\u0000") | map(select(. != "") | split("\t") as $e
		| {key: ($e[1:] | join("\t")), value: ($e[0] | split(" ") | "\(.[0]) \(.[2])")}) | from_entries) as $tree
	| ($head != "" and $head != $record[0].head) as $moved
	| [$record[0].paths, $states[0]] | transpose
	| map(.[0] as $p | .[1].state as $now
		| {path: $p.path, now:
			(if $moved and $now == ($tree[$p.path] // "absent") then "committed"
			 elif $now == $p.after then "mounted"
			 elif $now == "absent" then "gone"
			 else "edited" end)}) as $paths
	| {head: (if $head == "" then null else $head end), head_moved: $moved,
	   finished: ($moved and all($paths[]; .now == "committed")), paths: $paths}' "${gm_work}/head-tree"
