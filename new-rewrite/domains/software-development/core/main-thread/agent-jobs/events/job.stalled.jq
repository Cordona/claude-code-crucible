# job.stalled: a job whose report was accepted, but whose hand-in didn't
# finish: {job, iteration, fix_round?, agent, step, fault}, the stamps the
# job's own, fault the line the human was told. The report is kept; main
# finishes the hand-in or gives it up. Written by fault-stalled.sh, when the
# stop hook fails at stamp, pin, commit, event, lock or hook; or at step
# event by end-gone-jobs.sh or end-job.sh, for a job whose agent is gone
# with its report pinned and no submission. A job stalls once.
include "agent-jobs/scripts/lib/jobs";
def writers: {"fault-stalled.sh": ["stamp", "pin", "commit", "event", "lock", "hook"],
	"end-gone-jobs.sh": ["event"], "end-job.sh": ["event"]};
.event as $e | $e.body as $b | .prior as $all
| (if writers | has($e.by) then empty else "job.stalled is written only by \(writers | keys | join(", "))" end),
  ((($b | keys) - ["job", "iteration", "fix_round", "agent", "step", "fault"])[] | "\(.) is not a job.stalled field"),
  (if (writers | has($e.by) | not) or any(writers[$e.by][]; . == $b.step) then empty
   else "step must be one of \(writers[$e.by] | join(", ")), for \($e.by)" end),
  (if $b.fault | jobs_one_line then empty else "fault must be the one line the human was told" end),
  (if ($b.job | type) != "number" or ($all | jobs_dispatch($b.job)) == null then "job must be the seq of a dispatched job"
   else ($all | jobs_state($b.job)) as $state
	| (if $state == "assigned" then empty else "job \($b.job) is \($state); only a running job stalls" end),
	  (if $b | has("agent") then empty else "agent must be the agent job \($b.job) is assigned to" end),
	  ($all | jobs_stamp_problems($b))
   end)
