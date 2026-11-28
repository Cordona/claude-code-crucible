# An effort's trees, read from its worktree.* events. A module: load it with
# jq -L <this folder> and include "trees".
# live_trees reads the events array and gives the live trees, oldest cut
# first: each worktree.cut not followed by a worktree.dropped of its name, as
# {name, repo, path, branch, from, cut_base, base, seq}; cut_base is the
# cut's base, base the newest worktree.moved's to after it, else the cut's.

def live_trees:
	reduce .[] as $e ({};
		if $e.type == "worktree.cut" then
			.[$e.body.name] = ($e.body | {name, repo, path, branch, from, cut_base: .base, base, seq: $e.seq})
		elif $e.type == "worktree.moved" and has($e.body.name) then .[$e.body.name].base = $e.body.to
		elif $e.type == "worktree.dropped" then del(.[$e.body.name])
		else . end)
	| [.[]] | sort_by(.seq);
