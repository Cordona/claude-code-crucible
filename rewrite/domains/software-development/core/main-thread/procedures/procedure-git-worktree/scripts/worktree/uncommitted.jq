# What keeps a seat's worktree from counting as clean. A module: load it with
# jq -L <this folder> and include "uncommitted".
# uncommitted_paths($seat) reads `git status --porcelain=v1 -z` of the seat's
# worktree (jq -R -s) and gives each path with an uncommitted change, a
# rename or copy by its new path, except the seat's own two fault logs: the
# hooks append to them after a commit, and the seat's next commit takes them in.

# The fault logs seat-bind-hook.sh and report-commit-hook.sh append to.
def uncommitted_fault_logs($seat):
	".crucible/seats/\($seat)/" as $folder | ["\($folder)bind-hook-faults.log", "\($folder)stop-hook-faults.log"];

def uncommitted_paths($seat):
	uncommitted_fault_logs($seat) as $logs
	| reduce (split("\u0000")[] | select(. != "")) as $entry ({paths: [], source_next: false};
		if .source_next then .source_next = false
		else ($entry[0:2] | test("[RC]")) as $moved | ($entry[3:]) as $path
		| .source_next = $moved
		| if $moved or (any($logs[]; . == $path) | not) then .paths += [$path] else . end
		end)
	| .paths[];
