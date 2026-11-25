# job.refused: one refusal of a job's report, written by held-stop.sh:
# {job, iteration, fix_round?, agent, try, lines}, the stamps the job's own;
# try counts the job's refusals from 1, lines are the repair lines the agent
# got. A refusal holds the stop: the job runs on.
include "agent-jobs/scripts/lib/jobs";
.event as $e | $e.body as $b | .prior as $all
| (if $e.by == "held-stop.sh" then empty else "job.refused is written only by held-stop.sh" end),
  ((($b | keys) - ["job", "iteration", "fix_round", "agent", "try", "lines"])[] | "\(.) is not a job.refused field"),
  (if ($b.lines | type) == "array" and ($b.lines | length) > 0 and all($b.lines[]; jobs_one_line) then empty
   else "lines must be the repair lines, one line each, at least one" end),
  (if ($b.job | type) != "number" or ($all | jobs_dispatch($b.job)) == null then "job must be the seq of a dispatched job"
   else ($all | jobs_state($b.job)) as $state
	| ($all | jobs_refusals($b.job) | length + 1) as $next
	| (if $state == "assigned" then empty else "job \($b.job) is \($state); only a running job is refused" end),
	  (if $b.try == $next then empty else "try must be \($next), one more than job \($b.job)'s refusals so far" end),
	  ($all | jobs_stamp_problems($b))
   end)
