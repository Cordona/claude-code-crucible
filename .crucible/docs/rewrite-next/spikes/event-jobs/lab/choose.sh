#!/bin/sh
# Spike: records the human's answer at a gate. The root is always derived
# from the event the answer is about.
# usage: choose.sh --effort DIR [--check] [--session ID] ONE OF
#   --merge SEQ [--severity a,b] [--plus IDS] [--minus IDS] --cap N   fix.chosen from a query
#   --merge SEQ --none                                                fix.none
#   --plan SEQ                                                        plan.approved
#   --waive IDS --reason TEXT                                         waiver
#   --stop [--loop SEQ] --reason TEXT                                 loop.stopped
#   --fact KEY                                                        fact.answered (no)
#   --close SEQ --reason TEXT                                         root.closed
set -eu
LAB=$(cd "$(dirname "$0")" && pwd); . "$LAB/cli.sh"
parse_opts "$@"

# finish TYPE: refuses, checks or writes the event plan_step plans
finish() {
	plan=$(plan_step)
	printf '%s' "$plan" | jq -e .ok >/dev/null || refusal "$plan"
	[ -z "${opt_check:-}" ] || { echo '{"ok":true}'; exit 0; }
	seq=$(write "$1" "$(printf '%s' "$plan" | jq -r .root)" null null "$(printf '%s' "$plan" | jq -c .body)") || recheck $?
	jq -nc --argjson s "$seq" '{ok: true, seq: $s}'
	exit 0
}

if [ -n "${opt_merge:-}" ]; then
	need_seq merge "$opt_merge"
	decided='first(.[] | select((.type | IN("fix.chosen", "fix.none")) and .body.merge == $m)) as $d'
	if [ -n "${opt_none:-}" ]; then
		plan_step() { evq --argjson m "$opt_merge" 'include "ev"; ev($m) as $M
			| if $M.type != "review.merged" then {ok: false, refusal: "not-a-merge"} else
			  ('"$decided"' | {ok: false, refusal: "done-already", by: $d.seq})
			  // {ok: true, root: $M.root, body: {merge: $m}} end'; }
		finish fix.none
	fi
	need_seq cap "${opt_cap:-}"
	plan_step() { evq --argjson m "$opt_merge" --argjson cap "$opt_cap" \
		--argjson sev "$(list_json "${opt_severity:-}")" --argjson plus "$(list_json "${opt_plus:-}")" \
		--argjson minus "$(list_json "${opt_minus:-}")" 'include "ev"; ev($m) as $M
		| if $M.type != "review.merged" then {ok: false, refusal: "not-a-merge"} else
		  ('"$decided"' | {ok: false, refusal: "done-already", by: $d.seq})
		  // ([$M.body.findings[].id] as $known
		     | ([$M.body.findings[] | select(.status == "open" and .realism == "realistic" and (.severity | IN($sev[]))) | .id]
		        - $minus + [$plus[] | select(IN($known[]))] | unique) as $ids
		     | if $ids == [] then {ok: false, refusal: "no-match"} else
		       {ok: true, root: $M.root, body: {merge: $m, ids: $ids, cap: $cap,
		        query: ({severities: $sev, plus: $plus, minus: $minus} | with_entries(select(.value != [])))}} end)
		  end'; }
	finish fix.chosen
fi

if [ -n "${opt_plan:-}" ]; then
	need_seq plan "$opt_plan"
	plan_step() { evq --argjson p "$opt_plan" 'include "ev"; ev($p) as $P
		| if $P.type != "plan.submitted" then {ok: false, refusal: "not-a-plan"} else
		  (first(.[] | select(.type == "plan.approved" and .body.plan == $p)) | {ok: false, refusal: "done-already", by: .seq})
		  // {ok: true, root: $P.root, body: {plan: $p}} end'; }
	finish plan.approved
fi

if [ -n "${opt_waive:-}" ]; then
	[ -n "${opt_reason:-}" ] || die 1 "--waive needs --reason"
	plan_step() { evq --argjson ids "$(list_json "$opt_waive")" --arg why "$opt_reason" 'include "ev";
		[all_raised[] | select(.id | IN($ids[]))] as $found
		| ($found | map(.root) | unique) as $roots
		| if ($found | length) != ($ids | length) or ($roots | length) != 1 then {ok: false, refusal: "unknown-ids"}
		  else {ok: true, root: $roots[0], body: {ids: $ids, reason: $why}} end'; }
	finish waiver
fi

if [ -n "${opt_stop:-}" ]; then
	[ -n "${opt_reason:-}" ] || die 1 "--stop needs --reason"
	plan_step() { evq --argjson l "${opt_loop:-null}" --arg why "$opt_reason" 'include "ev"; . as $e
		| [.[] | .root | select(. != null)] | unique | map(. as $r | $e | live_loop($r) | select(. != null))
		| map(select($l == null or .seq == $l)) as $live
		| if ($live | length) != 1 then {ok: false, refusal: "no-live-loop"}
		  elif ($e | loop_stopped($live[0])) then {ok: false, refusal: "done-already",
		       by: ($e | [.[] | select(.type == "loop.stopped" and .root == $live[0].root)] | last | .seq)}
		  else {ok: true, root: $live[0].root, body: {reason: $why}} end'; }
	finish loop.stopped
fi

if [ -n "${opt_fact:-}" ]; then
	plan_step() { evq --arg k "$opt_fact" 'include "ev";
		($k | capture("^[a-z-]+:(?<s>[0-9]+)$") | .s | tonumber) as $s
		| ev($s) as $S
		| if $S == null or $S.root == null then {ok: false, refusal: "unknown-fact"}
		  else (first(.[] | select(.type == "fact.answered" and .body.fact == $k)) | {ok: false, refusal: "done-already", by: .seq})
		       // {ok: true, root: $S.root, body: {fact: $k, answer: "no"}} end'; }
	finish fact.answered
fi

if [ -n "${opt_close:-}" ]; then
	need_seq close "$opt_close"
	[ -n "${opt_reason:-}" ] || die 1 "--close needs --reason"
	plan_step() { evq --argjson s "$opt_close" --arg why "$opt_reason" 'include "ev"; ev($s) as $S
		| if $S == null or $S.root == null then {ok: false, refusal: "no-root"}
		  else (first(.[] | select(.type == "root.closed" and .root == $S.root)) | {ok: false, refusal: "done-already", by: .seq})
		       // {ok: true, root: $S.root, body: {reason: $why}} end'; }
	finish root.closed
fi

die 1 "nothing to record: give --merge, --plan, --waive, --stop, --fact or --close"
