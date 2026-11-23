# worktree.cut: a tree cut by worktree-cut.sh, {name, repo, path, branch,
# base, from, signed?}: path <effort>/worktrees/<name>, branch
# crucible/<effort folder name>/<name>, base the commit it was cut at, from
# what was asked for, signed whether a base the cut made carries a
# signature: present exactly when from is snapshot or several trees.
# Whether the name is free is worktree-cut.sh's question to
# worktree-trees.sh; this rule never replays the trees.
def sha: type == "string" and test("^[0-9a-f]{40}([0-9a-f]{24})?$");
def tree_name: type == "string" and test("^[a-z][a-z0-9]*(-[a-z0-9]+)*$");
.event as $e | $e.body as $b
| (if $e.by == "worktree-cut.sh" then empty else "worktree.cut is written only by worktree-cut.sh" end),
  ((($b | keys) - ["name", "repo", "path", "branch", "base", "from", "signed"])[] | "\(.) is not a worktree.cut field"),
  (if $b.name | tree_name then empty else "name must be lowercase words joined by dashes" end),
  (if ($b.repo | type) == "string" and ($b.repo | startswith("/")) then empty else "repo must be an absolute folder" end),
  (if ($b.path | type) == "string" and ($b.path | startswith("/")) and ($b.path | endswith("/worktrees/\($b.name)"))
   then empty else "path must be <effort>/worktrees/<name>, absolute" end),
  (if ($b.branch | type) == "string" and ($b.branch | test("^crucible/[^/]+/")) and ($b.branch | endswith("/\($b.name)"))
	and ($b.branch | split("/") | length) == 3
   then empty else "branch must be crucible/<effort folder name>/<name>" end),
  (if $b.base | sha then empty else "base must be a full commit sha" end),
  (if ($b.from | type) == "string"
	and ($b.from | test("^(checkout|snapshot|ref:[^[:space:][:cntrl:]]+|worktree:[a-z][a-z0-9]*(-[a-z0-9]+)*( worktree:[a-z][a-z0-9]*(-[a-z0-9]+)*)*)$"))
   then empty else "from must be checkout, snapshot, ref:<ref> or worktree:<name>, the last repeated with one space" end),
  (if ($b.from | type) == "string" and ($b.from == "snapshot" or ($b.from | contains(" "))) then
		(if ($b.signed | type) == "boolean" then empty else "signed must be a boolean when the cut made its base (from snapshot or several trees)" end)
   elif $b | has("signed") then "signed belongs only to a cut that made its base (from snapshot or several trees)"
   else empty end)
