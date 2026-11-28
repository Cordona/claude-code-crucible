# A job's state, read from an effort's events, a jq module: load it with
# jq -L <this folder> and include "jobs", or from an event rule as
# include "jobs-track/scripts/lib/jobs". A def reads the events, in seq
# order, as its input, unless it says otherwise. A job starts at its job.defined
# (or, for a kind not moved yet, its job.dispatched),
# whose seq is the job's key; job.assigned names its agent; a submission (an
# event whose body names the job and pins its report) or a job.ended
# finishes it. A job.stalled neither finishes it nor lets its agent take it
# up again: the report was accepted, and handing it in waits for main.

def jobs_assigned($job): [.[] | select(.type == "job.assigned" and .body.job == $job)] | first;

# A job defined by jobs-define, as the agent side reads a job: {kind, tree,
# report, known_failures, iteration, setup, base?, head?, refs, lens}, tree
# its worktree.cut's path once it has one, report under reports/KIND/, refs
# the job's input refs by name, as defined: what each ref means is the
# agent's to read; lens the first standard, a reviewer's finding IDs' start.
def jobs_view($d):
	. as $all | $d.body as $b
	| ((jobs_assigned($d.seq).body.tree) // $b.work.tree.use // null) as $t
	| {kind: $b.kind,
	   tree: (first($all[] | select(.seq == $t and .type == "worktree.cut") | .body.path) // null),
	   report: "reports/\($b.kind)/\($d.seq).json",
	   known_failures: ($b.work.known_failures // []), iteration: $b.work.loop.iteration, setup: $b.plugins}
	+ (if $b.work.range then {base: $b.work.range.base, head: $b.work.range.head} else {} end)
	+ {refs: ($b.input_refs // {})}
	+ {lens: $b.plugins.standards[0]};

# A job's start: its job.defined as the view above, or, for a kind not yet
# defined through jobs-define, its job.dispatched as written, its plan also
# given as a plan ref, so the agents read refs alone.
def jobs_dispatch($job):
	(first(.[] | select((.type == "job.dispatched" or .type == "job.defined") and .seq == $job)) // null) as $e
	| if $e == null then null
	  elif $e.type == "job.dispatched" then $e | .body += (if .body | has("plan") then {refs: {plan: .body.plan}} else {} end)
	  else {seq: $e.seq, type: $e.type, body: jobs_view($e)} end;

# Who runs a job: {agent, name, session}; name the job's readable name,
# session the session that assigned it. null before it is assigned.
def jobs_assignment($job):
	jobs_assigned($job) as $a
	| if $a == null then null
	  elif $a.body | has("name") then $a.body | {agent, name, session}
	  else {agent: $a.body.agent, name: "\(jobs_dispatch($job).body.kind)-\($job)", session: $a.claude_session_id} end;

def jobs_finish($job):
	[.[] | select((.type == "job.ended" or (.body.report | type) == "object") and .body.job == $job)] | first;

def jobs_stalled($job): [.[] | select(.type == "job.stalled" and .body.job == $job)] | first;

# The job's job.refused events, in seq order.
def jobs_refusals($job): [.[] | select(.type == "job.refused" and .body.job == $job)];

# dispatched, assigned, stalled, submitted or ended; null for no such job.
def jobs_state($job):
	if jobs_dispatch($job) == null then null
	else jobs_finish($job) as $end
		| if $end != null then (if $end.type == "job.ended" then "ended" else "submitted" end)
		  elif jobs_assigned($job) == null then "dispatched"
		  elif jobs_stalled($job) != null then "stalled"
		  else "assigned" end
	end;

# The stamps an event of job $job carries, copied from its job: {job,
# iteration?, fix_round?, agent?}, agent once the job is assigned.
def jobs_stamps($job):
	(jobs_dispatch($job).body) as $d
	| jobs_assigned($job) as $a
	| {job: $job} + ($d | with_entries(select(.key == "iteration" or .key == "fix_round")))
	+ (if $a == null then {} else {agent: $a.body.agent} end);

# The problems of event body $b's stamps against its dispatched job:
# iteration and fix_round the job's own, agent the assigned one, or none
# when no agent is assigned.
def jobs_stamp_problems($b):
	jobs_dispatch($b.job) as $job
	| jobs_assigned($b.job) as $assigned
	| (if $b.iteration == $job.body.iteration then empty else "iteration must be job \($b.job)'s, \($job.body.iteration)" end),
	  (if $b.fix_round == $job.body.fix_round then empty
	   elif $job.body | has("fix_round") then "fix_round must be job \($b.job)'s, \($job.body.fix_round)"
	   else "fix_round belongs only to a fix" end),
	  (if $assigned == null then (if $b | has("agent") then "job \($b.job) has no agent assigned, so its events name none" else empty end)
	   elif $b.agent == $assigned.body.agent then empty
	   else "agent must be \($assigned.body.agent), the agent job \($b.job) is assigned to" end);

# Input a string: one line of text, as a fault or a note.
def jobs_one_line: type == "string" and test("\\S") and (test("[\\r\\n]") | not);

# The seqs of the jobs agent $agent is working on: assigned, not finished.
def jobs_open_of($agent):
	. as $all
	| [.[] | select(.type == "job.assigned" and .body.agent == $agent) | .body.job
		| select(. as $job | $all | jobs_state($job) == "assigned")];

# Input a string: a full commit sha.
def jobs_sha: type == "string" and test("^[0-9a-f]{40}([0-9a-f]{24})?$");

# The problems of a submission event, read from an event rule's input
# {event, prior}: every agent's submission rule uses it. The body is {job,
# iteration, fix_round?, agent, report: {path, sha256}, commit?}, its stamps
# the job's own, written by agent-submission's submission step or by its
# recovery of a working commit. Which event a job's kind submits, and
# whether it commits, is said once, in the agent's <kind>-submission.json,
# which both writers follow.
def jobs_submission_problems:
	.event as $e | $e.body as $b | .prior as $all
	| (if $e.by == "submission-event.sh" or $e.by == "recover-submission.sh" then empty
	   else "\($e.type) is written only by submission-event.sh or recover-submission.sh" end),
	  ((($b | keys) - ["job", "iteration", "fix_round", "agent", "report", "commit"])[] | "\(.) is not a \($e.type) field"),
	  (if ($b | has("commit")) and ($b.commit | jobs_sha | not) then "commit must be a full commit sha" else empty end),
	  (if ($b.job | type) != "number" then "job must be the seq of the job's job.dispatched"
	   else ($all | jobs_dispatch($b.job)) as $job
		| if $job == null then "job \($b.job) is not a dispatched job"
		  else
			(($all | jobs_finish($b.job)) as $end
			 | if $end == null then empty else "job \($b.job) already ended, by event \($end.seq) (\($end.type))" end),
			(($all | jobs_assigned($b.job) | .body.agent) as $agent
			 | if $agent == null then "job \($b.job) has no agent assigned"
			   elif $b.agent != $agent then "agent must be \($agent), the agent job \($b.job) is assigned to"
			   else empty end),
			(if $b.iteration == $job.body.iteration then empty else "iteration must be job \($b.job)'s, \($job.body.iteration)" end),
			(if $b.fix_round == $job.body.fix_round then empty
			 elif $job.body | has("fix_round") then "fix_round must be job \($b.job)'s, \($job.body.fix_round)"
			 else "fix_round belongs only to a fix" end),
			(if ($b.report | type) == "object" and ($b.report | keys) == ["path", "sha256"]
				and $b.report.path == $job.body.report
				and ($b.report.sha256 | type) == "string" and ($b.report.sha256 | test("^[0-9a-f]{64}$"))
			 then empty else "report must be {path: \($job.body.report | tojson), sha256: the report's sha256}" end)
		  end
	   end);
