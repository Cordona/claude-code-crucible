#!/bin/sh
# Spike: merges a complete round into review.merged: every finding of the
# root with its latest status, the harvest's targets, the verdict and the
# slots left with no report. Refuses a second merge of one round.
# usage: merge.sh --effort DIR --round SEQ [--check] [--session ID]
set -eu
LAB=$(cd "$(dirname "$0")" && pwd); . "$LAB/cli.sh"
parse_opts "$@"
need_seq round "${opt_round:-}"

plan_step() {
	evq --argjson r "$opt_round" 'include "ev"; . as $e | ev($r) as $R
	| if $R.type != "round.made" or $R.body.kind == "challenge" then {ok: false, refusal: "not-a-review-round"}
	  elif merge_of($r) then {ok: false, refusal: "done-already", by: merge_of($r).seq}
	  elif (settled($R) | not) then {ok: false, refusal: "round-open"}
	  else
		(last(.[] | .seq)) as $now
		| skipped_ids($R.root; $now) as $sk
		| [findings_status($R.root; $now)[]
		   | {id, kind, file, severity, realism,
		      status: (if .status == "open" and (.id | IN($sk[])) then "skipped" else .status end)}] as $list
		| merge_targets($R.root; $R; $list; $now + 1) as $t
		| {ok: true, root: $R.root,
		   body: {findings: $list, verdict: (if $t == [] then "pass" else "changes" end), targets: $t, gaps: gaps($R)}}
	  end'
}
plan=$(plan_step)
printf '%s' "$plan" | jq -e .ok >/dev/null || refusal "$plan"
[ -z "${opt_check:-}" ] || { echo '{"ok":true}'; exit 0; }
root=$(printf '%s' "$plan" | jq -r .root)
seq=$(write review.merged "$root" "$opt_round" null "$(printf '%s' "$plan" | jq -c .body)") || recheck $?
# the merge's totals, so main can tell the human what was found
printf '%s' "$plan" | jq -c --argjson s "$seq" '.body as $b | {ok: true, merged: $s, verdict: $b.verdict,
	open: ([$b.findings[] | select(.status | IN("open", "insisted", "ruled-fix")) | .severity] | group_by(.) | map({key: .[0], value: length}) | from_entries),
	to_fix: $b.targets, no_report: ($b.gaps // [])}'
