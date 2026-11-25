# The one count of a job's iteration and fix round, a jq module: load it
# with jq -L <this folder> and include "iteration", or from an event rule as
# include "agent-jobs/scripts/lib/iteration". Each def reads an effort's
# earlier events, in seq order, as its input. A build's dispatch takes the
# next iteration on its tree; every other job takes its tree's current
# iteration, and a fix also the next round of its fix loop. Every later
# event copies both from its job, so nothing counts them again.

def it_builds($tree):
	map(select(.type == "job.dispatched" and .body.kind == "build" and .body.tree == $tree));

# The jobs that ended before their report was accepted: ended, never
# stalled. Such a build made no working commit.
def it_ended_unaccepted:
	[.[] | select(.type == "job.stalled") | .body.job] as $stalled
	| [.[] | select(.type == "job.ended") | .body.job | select(. as $j | $stalled | any(.[]; . == $j) | not)];

# One past the newest iteration on $tree whose build wasn't ended before
# acceptance: such a build is replaced under its own number.
def next_iteration($tree):
	it_ended_unaccepted as $gone
	| [it_builds($tree)[] | select(.seq as $s | $gone | any(.[]; . == $s) | not) | .body.iteration]
	| (max // 0) + 1;

# The iteration of $tree's newest build, which a fix on it belongs to; null
# when the tree has had no build.
def current_iteration($tree): [it_builds($tree)[] | .body.iteration] | last;

# A fix is a job that carries the findings the human chose.
def it_is_fix: has("findings");

# 1 when the fix starts a loop ($new_loop: it carries findings the human sent
# back after a decline) or is the first fix of kind $kind in the iteration;
# else one past the round of that kind's newest fix in it. Each kind of fix
# counts its own rounds. The kind stands in for the loop: a loop is the
# human's fix choice, which has no event yet.
def next_fix_round($tree; $iteration; $kind; $new_loop):
	if $new_loop then 1
	else [.[] | select(.type == "job.dispatched" and (.body | it_is_fix) and .body.kind == $kind
			and .body.tree == $tree and .body.iteration == $iteration) | .body.fix_round]
		| (last // 0) + 1
	end;
