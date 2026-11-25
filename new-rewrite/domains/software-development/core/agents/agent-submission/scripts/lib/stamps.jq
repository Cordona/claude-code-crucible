# The stamps an event of a job carries, copied from the job, a jq module:
# load it with jq -L <this folder> and include "stamps". Input: the job, as
# agent-jobs' job-of.sh prints it. Keys come in the order they are printed:
# job, iteration (none for a job on a tree with no build), fix_round (when
# the job has one), agent, then the event's own.

def st_stamps: {job} + (if has("iteration") then {iteration} else {} end)
	+ (if has("fix_round") then {fix_round} else {} end) + {agent};

# A submission's body; $commit "" when the tree didn't change.
def st_submission($sha256; $commit):
	st_stamps + {report: {path: .report, sha256: $sha256}} + (if $commit == "" then {} else {commit: $commit} end);
