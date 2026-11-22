#!/usr/bin/env sh
# Adds open questions to a grill, each with its recommended answer and why.
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh grill-add.sh --grill PATH --question TEXT --recommendation TEXT
       --reason TEXT [--parent ID] [--question ...]...
       sh grill-add.sh --help | -h

Appends one open question per --question group, in order, with the next
free ids (q1, q2, ...).

  --grill PATH            the open grill's draft, as grill-new.sh printed it
  --question TEXT         starts a group: the question, one line
  --recommendation TEXT   the answer recommended, one line
  --reason TEXT           why, one line
  --parent ID             the question it came from

stdout: the new ids, in order, comma-separated
Exit: 0 added; 2 refused, nothing written, the reason on stderr
USAGE
}

gr_prog='grill-add.sh'
. "$(dirname -- "$0")/lib/grill.sh"
grill='' groups='[]'
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--grill) [ $# -ge 2 ] || gr_refuse '--grill needs a value'; grill=$2; shift 2 ;;
		--question) [ $# -ge 2 ] || gr_refuse '--question needs a value'
			groups=$(printf '%s' "${groups}" | jq -c --arg t "$2" '. + [{text: $t}]'); shift 2 ;;
		--recommendation | --reason | --parent)
			[ $# -ge 2 ] || gr_refuse "$1 needs a value"
			[ "${groups}" != '[]' ] || gr_refuse "$1 comes before any --question"
			groups=$(printf '%s' "${groups}" | jq -c --arg k "${1#--}" --arg v "$2" '.[-1][$k] = $v'); shift 2 ;;
		*) gr_refuse "unknown argument $1; try --help" ;;
	esac
done
[ "${groups}" != '[]' ] || gr_refuse 'give at least one --question'
gr_set_grill "${grill}"
gr_require_open
gr_lock
# shellcheck disable=SC2016 # the $ names are jq's
result=$(jq -c --argjson groups "${groups}" '
	([.questions[].id | ltrimstr("q") | tonumber] | max // 0) as $last
	| reduce ($groups | to_entries[]) as $g (.;
		.questions += [{id: "q\($last + $g.key + 1)"}
			+ (if $g.value.parent then {parent: $g.value.parent} else {} end)
			+ {text: $g.value.text,
			   recommendation: {text: ($g.value.recommendation // ""), reason: ($g.value.reason // "")},
			   status: "open", answers: []}])
	| {grill: ., ids: [range($last + 1; $last + 1 + ($groups | length)) | "q\(.)"]}' "${gr_file}")
printf '%s' "${result}" | jq '.grill' | gr_save "${gr_file}"
printf '%s' "${result}" | jq -r '.ids | join(",")'
