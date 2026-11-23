#!/usr/bin/env sh
# Asks the components beside this one whether something works in the named
# trees. Reads only.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2310,SC2312 # each gw_ function exits on its own failure, and one in a condition is there for its status; a read inside a message only shortens the message
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh worktree-busy.sh --effort FOLDER --name NAME [--name NAME]...

Run by the git-worktree scripts that change a tree and by mount-apply.sh; not
for main to call.
Asks every installed skill's scripts/internal/busy.sh whether anything still
works in the named trees; a line starting "busy", or a failed check, counts
as busy. Use it before changing, removing or mounting a tree.

Options:
  --effort FOLDER  the effort's folder, absolute; any effort state
  --name NAME      a tree name, not checked against the live trees; repeatable
Writes:    nothing
Stdout:    one JSON line {"busy": [string...]}, empty on exit 0; each entry is
           "<skill>: <name>: <busy line | busy.sh failed>"
Exit:
  0  nothing busy
  2  refused, nothing changed; the reason is on stderr
  4  git or jq missing, or no temp folder: fix it, then rerun
  5  at least one tree is busy
USAGE
}

gw_prog='worktree-busy.sh'
. "$(dirname -- "$0")/../lib/git-worktree.sh"
effort='' names=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--effort | --name)
			[ $# -ge 2 ] || gw_refuse "$1 needs a value"
			case $1 in
				--effort) effort=$2 ;;
				--name) gw_check_name "$2"; names="${names:+${names} }$2" ;;
				*) ;;
			esac
			shift 2 ;;
		*) gw_refuse "unknown argument $1; try --help" ;;
	esac
done
[ -n "${names}" ] || gw_refuse '--name needs a value'
gw_find_core "$0"
gw_check_effort "${effort}"
gw_make_work
# Each component's own scripts/internal/busy.sh answers for its work: a line
# starting "busy" names what works in the tree.
: >"${gw_work}/busy"
for check in "${gw_skills}"/*/scripts/internal/busy.sh; do
	[ -f "${check}" ] || continue
	component=${check%/scripts/internal/busy.sh}
	component=${component##*/}
	for name in ${names}; do
		if said=$(sh "${check}" --effort "${gw_effort_given}" --name "${name}" 2>/dev/null); then
			printf '%s\n' "${said}" | grep '^busy' | sed "s|^|${component}: ${name}: |" >>"${gw_work}/busy" || :
		else
			printf '%s: %s: busy.sh failed\n' "${component}" "${name}" >>"${gw_work}/busy"
		fi
	done
done
jq -Rnc '{busy: [inputs]}' "${gw_work}/busy"
[ ! -s "${gw_work}/busy" ] || exit 5
