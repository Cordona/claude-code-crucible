#!/usr/bin/env sh
# Prints the facts main chooses a tree's base from. Reads only.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2310,SC2312 # each gw_ function exits on its own failure, and one in a condition is there for its status; a read inside a test or a message gives an empty or wrong value the test then refuses, or only shortens the message
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh worktree-facts.sh --repo DIR [--effort FOLDER]

Prints the facts to choose a tree's base from, before a cut, move or
catch-up: the main checkout and, with --effort, the effort's live trees.

Options:
  --repo DIR       any folder of the main checkout or a worktree, absolute
  --effort FOLDER  an effort's folder, absolute; adds its trees
Writes:    nothing
Stdout:    one JSON object, about the main checkout:
  {repo, head: SHA|null, branch: refs/heads/NAME|null, uncommitted: N,
   trees: [{name, path, branch: NAME, tip: SHA|null, present: bool,
            uncommitted: N|null, in_checkout: bool, not_in: [NAME...]}]}
  head null: unborn; branch null: detached; uncommitted counts untracked.
  trees: this repository's only. tip null: branch gone; present false:
  folder gone, uncommitted null; in_checkout: head holds tip; not_in: other
  trees whose tip doesn't hold it.
Exit:
  0  printed
  2  refused, nothing changed; the reason is on stderr
  4  git, jq or a reader failed: check the install, rerun
USAGE
}

gw_prog='worktree-facts.sh'
. "$(dirname -- "$0")/../lib/git-worktree.sh"
repo_in='' effort=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--repo | --effort)
			[ $# -ge 2 ] || gw_refuse "$1 needs a value"
			case $1 in --repo) repo_in=$2 ;; --effort) effort=$2 ;; *) ;; esac
			shift 2 ;;
		*) gw_refuse "unknown argument $1; try --help" ;;
	esac
done
gw_find_core "$0"
gw_set_repo "${repo_in}"
[ -z "${effort}" ] || gw_check_effort "${effort}"
gw_make_work

head=$(git -C "${gw_repo}" rev-parse --verify --quiet 'HEAD^{commit}') || head=''
branch=$(git -C "${gw_repo}" symbolic-ref -q HEAD) || branch=''
uncommitted=$(gw_uncommitted "${gw_repo}")
jq -n --arg repo "${gw_repo}" --arg head "${head}" --arg branch "${branch}" --argjson n "${uncommitted}" \
	'{repo: $repo, head: ($head | if . == "" then null else . end),
	  branch: ($branch | if . == "" then null else . end), uncommitted: $n}' >"${gw_work}/facts"
if [ -z "${effort}" ]; then
	jq . "${gw_work}/facts"
	exit 0
fi

sh "${gw_scripts}/internal/worktree-trees.sh" --effort "${gw_effort_given}" >"${gw_work}/live" || exit $?
jq -c --arg r "${gw_repo}" '.[] | select(.repo == $r)' "${gw_work}/live" >"${gw_work}/trees"
: >"${gw_work}/tips"
while IFS= read -r tree; do
	gw_tree_name=$(printf '%s' "${tree}" | jq -r '.name')
	gw_tree_path=$(printf '%s' "${tree}" | jq -r '.path')
	gw_tree_branch=$(printf '%s' "${tree}" | jq -r '.branch')
	gw_tree_repo=${gw_repo}
	tip=$(gw_branch_tip)
	present=false tree_uncommitted=null
	if [ -d "${gw_tree_path}" ]; then
		present=true
		tree_uncommitted=$(gw_uncommitted "${gw_tree_path}")
	fi
	in_checkout=false
	if [ -n "${tip}" ] && [ -n "${head}" ] && git -C "${gw_repo}" merge-base --is-ancestor "${tip}" "${head}" 2>/dev/null; then
		in_checkout=true
	fi
	printf '%s\n' "${tree}" | jq -c --arg tip "${tip}" --argjson present "${present}" \
		--argjson u "${tree_uncommitted}" --argjson c "${in_checkout}" \
		'{name, path, branch, tip: ($tip | if . == "" then null else . end), present: $present,
		  uncommitted: $u, in_checkout: $c}' >>"${gw_work}/tips"
done <"${gw_work}/trees"

# not_in: for each tree, the other trees whose tip doesn't hold its tip.
: >"${gw_work}/held"
while IFS= read -r one; do
	one_name=$(printf '%s' "${one}" | jq -r '.name')
	one_tip=$(printf '%s' "${one}" | jq -r '.tip // empty')
	while IFS= read -r other; do
		other_name=$(printf '%s' "${other}" | jq -r '.name')
		other_tip=$(printf '%s' "${other}" | jq -r '.tip // empty')
		[ "${other_name}" != "${one_name}" ] && [ -n "${one_tip}" ] || continue
		if [ -z "${other_tip}" ] || ! git -C "${gw_repo}" merge-base --is-ancestor "${one_tip}" "${other_tip}" 2>/dev/null; then
			jq -nc --arg n "${one_name}" --arg o "${other_name}" '{name: $n, not_in: $o}' >>"${gw_work}/held"
		fi
	done <"${gw_work}/tips"
done <"${gw_work}/tips"
jq -s --slurpfile facts "${gw_work}/facts" --slurpfile held "${gw_work}/held" '
	. as $trees
	| $facts[0] + {trees: [$trees[] | .name as $n | . + {not_in: [$held[] | select(.name == $n) | .not_in]}]}' \
	"${gw_work}/tips"
