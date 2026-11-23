#!/usr/bin/env sh
# Lists the trees a tree was cut from, directly and further back, and
# whether it holds each one's tip. Reads only.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2310,SC2312 # each gw_ function exits on its own failure, and one in a condition is there for its status; a read inside a test or a message gives an empty or wrong value the test then refuses, or only shortens the message
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh worktree-chain.sh --effort FOLDER --name NAME

Lists every tree the effort's live tree NAME was cut from, at any level,
nearest first, each once, with its tip now and whether NAME's branch holds
it. Use it to see if NAME is behind its sources; worktree-chain-sync.sh
takes the moved tips in. The effort may be open or closed.

Options:
  --effort FOLDER  the effort's folder, absolute
  --name NAME      a live tree of the effort whose branch still exists
Writes:    nothing
Stdout:    one JSON object {name, tip, ancestors: [{name, via, tip: SHA|null,
           held: bool}...], moved: bool}; via: the direct source it was
           reached through; tip null, held true: that tree was dropped or
           cut again, or its branch is gone; moved: any ancestor not held;
           ancestors [] when NAME was cut from no tree
Exit:
  0  printed
  2  refused, nothing changed; the reason is on stderr
  4  git or jq not found, mktemp failed, or core's events reader failed
USAGE
}

gw_prog='worktree-chain.sh'
. "$(dirname -- "$0")/../lib/git-worktree.sh"
effort='' name=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--effort | --name)
			[ $# -ge 2 ] || gw_refuse "$1 needs a value"
			case $1 in --effort) effort=$2 ;; --name) name=$2 ;; *) ;; esac
			shift 2 ;;
		*) gw_refuse "unknown argument $1; try --help" ;;
	esac
done
gw_find_core "$0"
gw_check_effort "${effort}"
gw_check_name "${name}"
gw_make_work
gw_read_events
gw_load_tree "${name}"
own_tip=$(gw_branch_tip)
[ -n "${own_tip}" ] || gw_refuse "tree ${name}'s branch ${gw_tree_branch} is gone"
repo=${gw_tree_repo}

# Each ancestor as {name, via, live}: live the tree of that name is the very
# cut the walk reached, so its tip is still there to take.
# shellcheck disable=SC2016 # the $ names are jq's
jq -c -L "${gw_lib}" --arg name "${name}" '
	include "trees";
	def tree_names: split(" ")[] | select(startswith("worktree:")) | ltrimstr("worktree:");
	. as $all | live_trees as $live
	| ($live[] | select(.name == $name)) as $me
	| {queue: [$me.from | tree_names | {name: ., via: ., before: $me.seq}], seen: [$name], found: []}
	| until(.queue == [];
		.queue[0] as $q | .queue |= .[1:]
		| if any(.seen[]; . == $q.name) then .
		else ([$all[] | select(.type == "worktree.cut" and .body.name == $q.name and .seq < $q.before)] | last) as $cut
			| .seen += [$q.name]
			| .found += [{name: $q.name, via: $q.via, live: any($live[]; .name == $q.name and .seq == $cut.seq)}]
			| .queue += [($cut.body.from // "") | tree_names | {name: ., via: $q.via, before: $cut.seq}]
		end)
	| .found[]' "${gw_work}/events" >"${gw_work}/found"

: >"${gw_work}/ancestors"
while IFS= read -r found; do
	ancestor=$(printf '%s' "${found}" | jq -r '.name')
	tip='' held=true
	if [ "$(printf '%s' "${found}" | jq -r '.live')" = true ]; then
		gw_load_tree "${ancestor}"
		tip=$(gw_branch_tip)
		if [ -n "${tip}" ] && ! git -C "${repo}" merge-base --is-ancestor "${tip}" "${own_tip}"; then held=false; fi
	fi
	printf '%s' "${found}" | jq -c --arg tip "${tip}" --argjson held "${held}" \
		'{name, via, tip: ($tip | if . == "" then null else . end), held: $held}' >>"${gw_work}/ancestors"
done <"${gw_work}/found"
jq -s --arg name "${name}" --arg tip "${own_tip}" \
	'{name: $name, tip: $tip, ancestors: ., moved: any(.[]; .held | not)}' "${gw_work}/ancestors"
