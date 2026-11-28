# job.ended: a job that ended without its submission: {job, iteration,
# fix_round?, agent?, reason, step?, fault?, note?}; the stamps are the
# job's own, agent once it is assigned. Each reason has its writers:
#   gave-up  held-stop.sh, after the job's second job.refused;
#   fault    {step, fault}, the line the human was told: fault-ended.sh,
#            before the report was accepted (step check or hook); or
#            recover-submission.sh, giving up on a stalled job;
#   no-stop  the agent is gone and never handed in: end-gone-jobs.sh, at
#            main's turn end; or end-job.sh, with main's note, which also
#            ends a job whose agent never started.
# The tree is kept for the next job.
include "jobs-track/scripts/lib/jobs";
def steps: ["check", "stamp", "pin", "commit", "event", "lock", "hook"];
def writers: {"gave-up": {"held-stop.sh": ["assigned"]},
	fault: {"fault-ended.sh": ["assigned"], "recover-submission.sh": ["stalled"]},
	"no-stop": {"end-gone-jobs.sh": ["assigned"], "end-job.sh": ["assigned", "dispatched"]}};
.event as $e | $e.body as $b | .prior as $all
| ($all | jobs_dispatch($b.job)) as $job
| (writers[$b.reason | strings] // null) as $by
| ((($b | keys) - ["job", "iteration", "fix_round", "agent", "reason", "step", "fault", "note"])[] | "\(.) is not a job.ended field"),
  (if $by == null then "reason must be gave-up, fault or no-stop"
   elif $by | has($e.by) then empty
   else "job.ended \($b.reason) is written only by \($by | keys | join(" or "))" end),
  (if $b.reason == "fault" then
	(if any(steps[]; . == $b.step) then empty else "step must be one of \(steps | join(", "))" end),
	(if $e.by == "fault-ended.sh" and ($b.step != "check" and $b.step != "hook")
	 then "before its report is accepted, a job faults at check or hook; a later fault stalls it" else empty end),
	(if $b.fault | jobs_one_line then empty else "fault must be the one line the human was told" end)
   elif ($b | has("step")) or ($b | has("fault")) then "step and fault belong to reason fault"
   else empty end),
  (if $e.by == "end-job.sh" then (if $b.note | jobs_one_line then empty else "note must be main's one line on why the job ended" end)
   elif $b | has("note") then "note belongs to end-job.sh's no-stop"
   else empty end),
  (if ($b.job | type) != "number" or $job == null then "job must be the seq of a dispatched job"
   else ($all | jobs_state($b.job)) as $state
	| (if $by == null or ($by | has($e.by) | not) or any($by[$e.by][]; . == $state) then empty
	   else "job \($b.job) is \($state); \($e.by) ends only a job that is \($by[$e.by] | join(" or "))" end),
	  (if $b.reason == "gave-up" and ($all | jobs_refusals($b.job) | length) != 2
	   then "a job gives up after its second job.refused" else empty end),
	  ($all | jobs_stamp_problems($b))
   end)
