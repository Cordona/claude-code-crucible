# Spike: a run's event sequence per root, with no seq or id, from the lab's
# view of its events. Delivery is kept only where the claim needs it (a fix,
# and the reviewers a loop round derives); elsewhere it is "any".
def sequence($run): . as $e
	| def ev($s): first($e[] | select(.seq == $s));
	  def jobof: if .type == "job.dispatched" then . elif .job then ev(.job) else null end;
	  def rootof: .root // ((jobof) as $j | if $j then ([$e[] | select(.job == $j.seq and .root != null)] | first | .root) else null end);
	  # C10 reopens the session with --continue, which keeps the session id and
	  # still reaches the agents, so its deliveries are left free
	  def delivery_claimed: $run != "C10" and .body.replaces == null
		and (.body.kind == "fix" or (.round != null and ev(.round).body.loop != null));
	  [$e[] | select(.type == "round.made")] as $rounds
	| [$e[] | {r: rootof, x: .}] | group_by(.r)
	| {run: $run,
	   compare: "per root, in order; the events of one round may interleave; \"any\" matches anything",
	   roots: [.[] | {root: (.[0].r | if . == null then "none" else ev(.).type end),
		events: [.[].x | (jobof) as $j | {type}
			+ (if $j then {kind: $j.body.kind, role: $j.body.agent_type} else {} end)
			+ (if .type == "job.dispatched" then {delivery: (if delivery_claimed then .body.delivery else "any" end), replaces: (.body.replaces != null)} else {} end)
			+ (if .round then (.round as $rd | {round: ([$rounds[] | select(.root == ev($rd).root) | .seq] | index($rd) + 1)}) else {} end)
			+ (if .type == "round.made" then {kind: .body.kind, slots: [.body.slots[].kind], loop: (.body.loop != null)} else {} end)
			+ (if .type | IN("job.ended", "loop.ended", "loop.stopped") then {reason: .body.reason} else {} end)
			+ (if .type == "gate.answered" then {step: .body.step, accepted: .body.accepted} else {} end)
			+ (if .type == "review.merged" then {verdict: .body.verdict, targets: (.body.targets | length), gaps: (.body.gaps | length)} else {} end)]}]};
