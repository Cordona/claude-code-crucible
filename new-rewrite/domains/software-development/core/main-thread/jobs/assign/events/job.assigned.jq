# job.assigned: the agent that runs a job. For a job defined through
# jobs-define: {job, agent, tree}, written by jobs-assign's job-assigned.sh
# when a fresh agent starts or job-sent.sh after a hot send; tree the
# worktree.cut the job works in. For a kind not moved yet, as dispatched:
# {job, agent, name, session}, written by assign-job.sh. A job is assigned
# once, and an agent works on one job at a time.
include "jobs-track/scripts/lib/jobs";
.event as $e | $e.body as $b | .prior as $all
| (first($all[] | select(.seq == $b.job and (.type == "job.defined" or .type == "job.dispatched"))) // null) as $start
| (if ($b.agent | type) == "string" and ($b.agent | test("^[A-Za-z0-9._-]+$")) then empty
   else "agent must be the agent's id: letters, digits, ., _ or -" end),
  (if ($b.job | type) != "number" or $start == null then "job must be the seq of the job's job.defined"
   elif $start.type == "job.defined" then
	(if $e.by == "job-assigned.sh" or $e.by == "job-sent.sh" then empty
	 else "a defined job's job.assigned is written only by job-assigned.sh or job-sent.sh" end),
	((($b | keys) - ["job", "agent", "tree"])[] | "\(.) is not a job.assigned field"),
	(if ($b.tree | type) == "number" and any($all[]; .seq == $b.tree and .type == "worktree.cut") then empty
	 else "tree must be the seq of the worktree.cut the job works in" end),
	(if $start.body.work.tree.use and $b.tree != $start.body.work.tree.use
	 then "job \($b.job) uses tree \($start.body.work.tree.use), not \($b.tree)" else empty end),
	(if $start.body.work.tree.cut and any($all[]; .type == "job.assigned" and .body.tree == $b.tree)
	 then "tree \($b.tree) is already another job's; job \($b.job) cuts a fresh one" else empty end)
   else
	(if $e.by == "assign-job.sh" then empty else "a dispatched job's job.assigned is written only by assign-job.sh" end),
	((($b | keys) - ["job", "agent", "name", "session"])[] | "\(.) is not a job.assigned field"),
	(if ($b.session | type) == "string" and ($b.session | test("^[A-Za-z0-9._-]+$")) then empty
	 else "session must be the assigning session's id: letters, digits, ., _ or -" end),
	(if ($b.name | type) == "string" and ($b.name | test("^[a-z][a-z0-9]*(-[a-z0-9]+)*$")) then empty
	 else "name must be lowercase words joined by dashes" end)
   end),
  (($all | jobs_state($b.job)) as $state
   | if $state == null or $state == "dispatched" then empty
     else "job \($b.job) is \($state); a job is assigned once" end),
  (($all | jobs_open_of($b.agent)) as $open
   | if ($open | length) == 0 then empty
     else "agent \($b.agent) still works on job \($open[0]); an agent works on one job at a time" end)
