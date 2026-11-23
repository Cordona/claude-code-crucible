#!/usr/bin/env sh
# Prints a grill for main to read: where it stands, and its questions.
# shellcheck source-path=SCRIPTDIR
set -eu

usage() {
	cat <<'USAGE'
usage: sh grill-show.sh --grill PATH [--open]

Prints one grill for main to read, open or ended. Use it before asking a
round, or to pick a grill back up.

Options:
  --grill PATH  an open grill's draft or an ended grill's grill.ended event;
                grill-list.sh prints these
  --open        print only the open questions; line 1 still counts all
Writes:    nothing
Stdout:    line 1: grill N · TOPIC · settled N · open N · deferred N ·
           dropped N; then per question:
             ID [STATUS] (from PARENT) TEXT
                recommended: TEXT (REASON)
                answer: TEXT       if settled, else last note: TEXT
           "(from PARENT)" only on a follow-up; the answer or note line
           only when the question has one.
Exit:
  0  printed
  2  refused, nothing changed; the reason is on stderr
USAGE
}

gr_prog='grill-show.sh'
. "$(dirname -- "$0")/../lib/grill.sh"
grill='' open=false
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--grill) [ $# -ge 2 ] || gr_refuse '--grill needs a value'; grill=$2; shift 2 ;;
		--open) open=true; shift ;;
		*) gr_refuse "unknown argument $1; try --help" ;;
	esac
done
[ -f "${grill}" ] || gr_refuse "${grill} is not a grill"
# shellcheck disable=SC2016 # the $ names are jq's
jq -r --argjson open "${open}" '
	(if .type == "grill.ended" then .body else . end) as $g
	| ($g.questions | group_by(.status) | map({(.[0].status): length}) | add // {}) as $n
	| "grill \($g.number) · \($g.topic) · settled \($n.settled // 0) · open \($n.open // 0) · deferred \($n.deferred // 0) · dropped \($n.dropped // 0)",
	  ($g.questions[] | select(($open | not) or .status == "open")
		| "\(.id) [\(.status)]\(if .parent then " (from \(.parent))" else "" end) \(.text)",
		  "   recommended: \(.recommendation.text) (\(.recommendation.reason))",
		  (if (.answers | length) == 0 then empty
		   elif .status == "settled" then "   answer: \(.answers[-1].text)"
		   else "   last note: \(.answers[-1].text)" end))' "${grill}" \
	|| gr_refuse "${grill} is not a grill"
