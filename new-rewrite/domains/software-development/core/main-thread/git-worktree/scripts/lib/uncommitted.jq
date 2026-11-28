# What keeps a worktree from counting as clean. A module: load it with
# jq -L <this folder> and include "uncommitted".
# uncommitted_paths reads `git status --porcelain=v1 -z` of a worktree
# (jq -R -s) and gives each path with an uncommitted change, a rename or
# copy by its new path. Every change counts.

def uncommitted_paths:
	reduce (split("\u0000")[] | select(. != "")) as $entry ({paths: [], source_next: false};
		if .source_next then .source_next = false
		else .source_next = ($entry[0:2] | test("[RC]")) | .paths += [$entry[3:]]
		end)
	| .paths[];
