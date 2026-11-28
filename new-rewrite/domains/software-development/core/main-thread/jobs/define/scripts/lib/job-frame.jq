# A job's frame, a jq module: load it with jq -L <the skills folder> and
# include "jobs-define/scripts/lib/job-frame". The shapes every job shares
# (plugins, input_refs, work) and the one count of a build's iteration, so
# resolve and the job.defined rule never count apart.

def jf_one_line: type == "string" and test("\\S") and (test("[\\r\\n]") | not);
def jf_lines: type == "array" and all(.[]; jf_one_line);
def jf_whole: type == "number" and . == floor and . >= 1;
def jf_sha: type == "string" and test("^[0-9a-f]{40}([0-9a-f]{24})?$");

# The problems of a plugins object: one language, any frameworks, at least
# one standard.
def jf_plugins_problems:
	if type != "object" then "plugins must be {language, frameworks?, standards}"
	else
		((keys - ["language", "frameworks", "standards"])[] | "plugins.\(.) is not a plugins field"),
		(if .language | jf_one_line then empty else "plugins.language must be one language, one line" end),
		(if (has("frameworks") | not) or (.frameworks | jf_lines) then empty
		 else "plugins.frameworks must be a list of one-line names, or left out" end),
		(if (.standards | jf_lines) and (.standards | length) > 0 then empty
		 else "plugins.standards must be a list of one-line names, at least one" end)
	end;

# The problems of a work.tree: {use: a worktree.cut's seq} or
# {cut: {repo, from}}. Input: the tree; $all the effort's events.
def jf_tree_problems($all):
	if type != "object" or (keys | length) != 1 then "work.tree must be {use: SEQ} or {cut: {repo, from}}"
	elif has("use") then
		(.use as $u | if ($u | jf_whole) and ([$all[] | select(.seq == $u and .type == "worktree.cut")] | length) == 1
		 then empty else "work.tree.use must be the seq of a worktree.cut" end)
	elif has("cut") then
		(.cut | if type != "object" then "work.tree.cut must be {repo, from}"
		 else ((keys - ["repo", "from"])[] | "work.tree.cut.\(.) is not a cut field"),
			(if (.repo | type) == "string" and (.repo | startswith("/")) then empty else "work.tree.cut.repo must be an absolute folder" end),
			(if (.from | type) == "string" and (.from | test("^(checkout|snapshot|ref:[^\\s]+|worktree:[a-z0-9][a-z0-9-]*( worktree:[a-z0-9][a-z0-9-]*)*)$")) then empty
			 else "work.tree.cut.from must be checkout, snapshot, ref:REF or worktree:NAME (repeatable), as worktree-cut.sh --from takes it" end)
		 end)
	else "work.tree must be {use: SEQ} or {cut: {repo, from}}" end;

# The iteration a job takes. A build opens one: 1 on a tree it cuts; on a
# tree it uses, one past the builds already defined on it, counting the
# build that cut it as 1. Every other kind takes its tree's current one.
# Only a build opens an iteration. Input: the job; $all the events before it.
def jf_builds_on($all; $t): [$all[] | select(.type == "job.defined" and .body.kind == "build" and .body.work.tree.use == $t)] | length;
def jf_iteration($all):
	if .kind == "build" then
		(if .work.tree.cut then 1 else 2 + jf_builds_on($all; .work.tree.use) end)
	else 1 + jf_builds_on($all; .work.tree.use) end;
