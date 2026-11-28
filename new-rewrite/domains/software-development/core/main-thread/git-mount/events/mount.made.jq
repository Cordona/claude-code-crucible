# mount.made: trees' work put into the human's checkout by mount-apply.sh,
# {repo, names, target, start, paths}: the repository, the trees mounted,
# the commit mounted, the commit its patch starts on, and how many paths it
# touched. Whether each name is a live tree is mount-apply.sh's question to
# git-worktree's worktree-trees.sh; this rule never replays the trees.
def sha: type == "string" and test("^[0-9a-f]{40}([0-9a-f]{24})?$");
.event as $e | $e.body as $b
| (if $e.by == "mount-apply.sh" then empty else "mount.made is written only by mount-apply.sh" end),
  ((($b | keys) - ["repo", "names", "target", "start", "paths"])[] | "\(.) is not a mount.made field"),
  (if ($b.repo | type) == "string" and ($b.repo | startswith("/")) then empty else "repo must be an absolute folder" end),
  (if ($b.names | type) == "array" and ($b.names | length) > 0 and ($b.names | unique | length) == ($b.names | length)
	and all($b.names[]; type == "string")
   then empty else "names must be a non-empty array of tree names, each once" end),
  (if ($b.target | sha) and ($b.start | sha) then empty else "target and start must be full commit shas" end),
  (if ($b.paths | type) == "number" and $b.paths >= 1 and ($b.paths | floor) == $b.paths then empty
   else "paths must be a whole number from 1" end)
