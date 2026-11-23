#!/usr/bin/env sh
# Adds open questions to a grill, each with its recommended answer and why.
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh grill-add.sh --grill FILE
         (--question TEXT --recommendation TEXT --reason TEXT [--parent ID])...

Adds open questions to a grill, each with its recommended answer and why.
Use it while grilling, to record a round's questions before asking them.

Options:
  --grill FILE           the grill draft, as grill-new.sh printed it
  --question TEXT        starts a group: one new question, one line; repeatable
  --recommendation TEXT  the recommended answer, one line; required per group
  --reason TEXT          why, one line; required per group
  --parent ID            the earlier question this follows from (q<N>, in the
                         grill or added earlier in this call)
  Group options follow their --question, in any order.
Requires:  the effort is open and the grill has not ended
Writes:    the grill draft; new questions get ids after the highest q<N>
Stdout:    the new ids, in order, comma-separated (q3,q4)
Exit:
  0  added
  2  refused, nothing written; the reason is on stderr
USAGE
}

gr_prog='grill-add.sh'
. "$(dirname -- "$0")/../lib/grill.sh"
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
