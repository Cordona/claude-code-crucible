#!/usr/bin/env sh
# Records the human's answers in a grill.
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh grill-answer.sh --grill FILE --id ID --text TEXT
         [--change-reason TEXT] [--id ID --text TEXT [--change-reason TEXT]]...

Records the human's answers in an open grill, one per --id group, each
question answered becoming settled. Use it after each round.

Options:
  --grill FILE          the open grill's draft, as grill-new.sh printed it
  --id ID               starts a group: a question (q<N>), not dropped
                        (grill-mark.sh --to open first)
  --text TEXT           the answer, one line
  --change-reason TEXT  why a settled answer changes, one line; required for
                        a settled question, refused for any other
Requires:  the effort is open
Writes:    the grill draft; a changed answer keeps the earlier ones, and
           reopens its settled children not answered in this call
Stdout:    "<id> settled" per answer, then "<id> open" per reopened child
Exit:
  0  recorded
  2  refused, nothing written; the reason is on stderr
USAGE
}

gr_prog='grill-answer.sh'
. "$(dirname -- "$0")/../lib/grill.sh"
grill='' groups='[]'
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--grill) [ $# -ge 2 ] || gr_refuse '--grill needs a value'; grill=$2; shift 2 ;;
		--id) [ $# -ge 2 ] || gr_refuse '--id needs a value'
			groups=$(printf '%s' "${groups}" | jq -c --arg v "$2" '. + [{id: $v}]'); shift 2 ;;
		--text | --change-reason)
			[ $# -ge 2 ] || gr_refuse "$1 needs a value"
			[ "${groups}" != '[]' ] || gr_refuse "$1 comes before any --id"
			groups=$(printf '%s' "${groups}" | jq -c --arg k "${1#--}" --arg v "$2" '.[-1][$k] = $v'); shift 2 ;;
		*) gr_refuse "unknown argument $1; try --help" ;;
	esac
done
[ "${groups}" != '[]' ] || gr_refuse 'give at least one --id'
gr_set_grill "${grill}"
gr_require_open
gr_lock
# shellcheck disable=SC2016 # the $ names are jq's
result=$(jq -c --argjson groups "${groups}" '
	def problem($g):
		(.questions | map(select(.id == $g.id)) | first) as $q
		| if $q == null then "\($g.id) is not a question of this grill"
		  elif $q.status == "dropped" then "\($g.id) is dropped; reopen it first"
		  elif $q.status == "settled" and (($g["change-reason"] // "") == "") then "\($g.id) is settled; changing it needs --change-reason"
		  elif $q.status != "settled" and $g["change-reason"] then "\($g.id) is not settled; --change-reason is only for a change"
		  else empty end;
	. as $grill
	| [$groups[] as $g | $grill | problem($g)] as $problems
	| if ($groups | map(.id) | unique | length) != ($groups | length) then {problems: ["an --id is given twice"]}
	  elif $problems != [] then {problems: $problems}
	  else
		($groups | map(.id)) as $answered
		| ([.questions[] | select(.status == "settled") | .id] as $settled
			| [$groups[] | select(.id as $i | $settled | index([$i])) | .id]) as $changed
		| reduce $groups[] as $g (.;
			.questions |= map(if .id == $g.id then
				.status = "settled"
				| .answers += [{text: $g.text} + (if $g["change-reason"] then {change_reason: $g["change-reason"]} else {} end)]
			  else . end))
		| .questions |= map(if (.parent as $p | $changed | index([$p])) and .status == "settled"
			and ((.id as $i | $answered | index([$i])) | not) then .status = "open" else . end)
		| {grill: ., said: ([.questions[] | select(.id as $i | $answered | index([$i])) | "\(.id) settled"]
			+ [.questions[] | select(.status == "open" and (.parent as $p | $changed | index([$p]))) | "\(.id) open"])}
	  end' "${gr_file}")
problems=$(printf '%s' "${result}" | jq -r '.problems // [] | join("; ")')
[ -z "${problems}" ] || gr_refuse "${problems}"
printf '%s' "${result}" | jq '.grill' | gr_save "${gr_file}"
printf '%s' "${result}" | jq -r '.said[]'
