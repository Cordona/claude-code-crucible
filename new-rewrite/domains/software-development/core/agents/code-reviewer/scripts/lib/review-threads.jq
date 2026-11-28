# The threads an external review judges, a jq module: load it with jq -L
# <the skills folder> and include "code-reviewer/scripts/lib/review-threads".
# Input: the effort's events as events-view.sh prints them, each fetch with
# its pinned threads under report; $job the job as job-of.sh prints it.

def rt_fetch($seq): first(.[] | select(.seq == $seq and .type == "remote-review.fetched")) // null;

# The threads the job's earlier judgement read: the fetch its earlier ref's
# job named (resolve picked the last judgement of the same change before
# this job), or null at the first.
def rt_earlier($job):
	. as $all
	| ($job.refs.earlier // null) as $s
	| if $s == null then null
	  else (first($all[] | select(.seq == $s)) | .body.job) as $j
		| (first($all[] | select(.seq == $j and .type == "job.defined")) | .body.input_refs.review) as $r
		| ($all | rt_fetch($r)) | if . == null then null else .report.threads end
	  end;

# A thread's fingerprint: what makes it changed when it moves.
def rt_mark: {resolved, comments: [.comments[] | {id, updated}]};

# {threads, judge}: threads every thread of the job's fetch, {id, source,
# role} of the comment that opened it; judge the ids of those a reviewer
# opened that are new or changed since the earlier fetch, all of them at
# the first. Null when the job names no review.
def rt_threads($job):
	if ($job.refs.review // null) == null then null
	else (rt_fetch($job.refs.review) | .report.threads // []) as $now
		| (rt_earlier($job) // []) as $then
		| ($then | map({key: .id, value: rt_mark}) | from_entries) as $seen
		| {threads: [$now[] | {id} + (.comments[0] | {source, role})],
		   judge: [$now[] | select(.comments[0].role == "reviewer")
			| select(($seen[.id] // null) != rt_mark) | .id]}
	end;
