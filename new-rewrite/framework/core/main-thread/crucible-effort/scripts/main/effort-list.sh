#!/usr/bin/env sh
# Lists the efforts, newest change first.
# shellcheck source-path=SCRIPTDIR
set -eu

usage() {
	cat <<'USAGE'
usage: sh effort-list.sh [--all]

Lists the open and paused efforts, newest change first. Use it to find an
effort's folder to pass as --effort to the other effort scripts.

Options:
  --all     closed efforts too
Reads:      CRUCIBLE_HOME, default $HOME/.crucible
Writes:     nothing
Stdout:     one tab-separated line per effort: <folder> <state> <name> <at>;
            folder absolute, state open|paused|closed:<outcome>, at the time
            of its newest effort event (UTC ISO-8601); nothing if none
Exit:
  0  listed
  2  refused, nothing changed; the reason is on stderr
  3  listed, but some efforts were skipped: their events can't be read; each
     is named on stderr with the reason
USAGE
}

ef_prog='effort-list.sh'
. "$(dirname -- "$0")/../lib/effort.sh"
all=false
case ${1-} in
	-h | --help) usage; exit 0 ;;
	--all) all=true ;;
	'') ;;
	*) ef_refuse "unknown argument $1; try --help" ;;
esac
[ -d "${ef_efforts}" ] || exit 0
# An effort is listed whole or not at all; one that can't be read is skipped
# and named, so it never hides the others.
summaries='' skipped=0
for folder in "${ef_efforts}"/*; do
	[ -d "${folder}/events" ] && [ ! -L "${folder}" ] || continue
	# shellcheck disable=SC2310 # ef_summary checks its reader itself and returns jq's status, so it needs no set -e here
	if summary=$(ef_summary "${folder}"); then
		summaries="${summaries}${summary}
"
	else
		printf '%s: skipped %s: its events cannot be read\n' "${ef_prog}" "${folder}" >&2
		skipped=$((skipped + 1))
	fi
done
printf '%s' "${summaries}" | jq -rs --argjson all "${all}" '
	map(select($all or .state != "closed")) | sort_by(.at) | reverse | .[]
	| [.folder, (if .state == "closed" then "closed:\(.outcome)" else .state end), .name, .at] | @tsv'
[ "${skipped}" -eq 0 ] || exit 3
