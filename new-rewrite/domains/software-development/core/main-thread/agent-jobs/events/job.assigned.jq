# job.assigned: the agent that runs a job, written by assign-job.sh:
# {job, agent, name, session}, job the seq of its job.dispatched, agent the
# agent's id, name the readable name the working commit's Job trailer
# carries, session the Claude Code session_id of the main that assigned it.
# A job is assigned once, and an agent works on one job at a time.
include "agent-jobs/scripts/lib/jobs";
.event as $e | $e.body as $b | .prior as $all
| (if $e.by == "assign-job.sh" then empty else "job.assigned is written only by assign-job.sh" end),
  ((($b | keys) - ["job", "agent", "name", "session"])[] | "\(.) is not a job.assigned field"),
  (if ($b.agent | type) == "string" and ($b.agent | test("^[A-Za-z0-9._-]+$")) then empty
   else "agent must be the agent's id: letters, digits, ., _ or -" end),
  (if ($b.session | type) == "string" and ($b.session | test("^[A-Za-z0-9._-]+$")) then empty
   else "session must be the assigning session's id: letters, digits, ., _ or -" end),
  (if ($b.name | type) == "string" and ($b.name | test("^[a-z][a-z0-9]*(-[a-z0-9]+)*$")) then empty
   else "name must be lowercase words joined by dashes" end),
  (($all | jobs_state($b.job)) as $state
   | if ($b.job | type) != "number" then "job must be the seq of the job's job.dispatched"
     elif $state == null then "job \($b.job) is not a dispatched job"
     elif $state != "dispatched" then "job \($b.job) is \($state); a job is assigned once"
     else empty end),
  (($all | jobs_open_of($b.agent)) as $open
   | if ($open | length) == 0 then empty
     else "agent \($b.agent) still works on job \($open[0]); an agent works on one job at a time" end)
