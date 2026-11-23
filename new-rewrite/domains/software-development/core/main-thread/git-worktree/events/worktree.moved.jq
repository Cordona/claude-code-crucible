# worktree.moved: a live tree's branch moved by worktree-move.sh, {name,
# from, to, kept?}: the old tip, the new one, and the ref the old tip was
# kept under when commits were left out.
# Whether name is a live tree is worktree-move.sh's question to
# worktree-trees.sh; this rule never replays the trees.
def sha: type == "string" and test("^[0-9a-f]{40}([0-9a-f]{24})?$");
.event as $e | $e.body as $b
| (if $e.by == "worktree-move.sh" then empty else "worktree.moved is written only by worktree-move.sh" end),
  ((($b | keys) - ["name", "from", "to", "kept"])[] | "\(.) is not a worktree.moved field"),
  (if ($b.name | type) == "string" then empty else "name must be a tree's name" end),
  (if ($b.from | sha) and ($b.to | sha) and $b.from != $b.to then empty else "from and to must be two different full commit shas" end),
  (if $b | has("kept") | not then empty
   elif ($b.kept | type) == "string" and ($b.kept | test("^refs/crucible/moved/[^/]+/[^/]+/[1-9][0-9]*$"))
	and ($b.kept | split("/")[4]) == $b.name
	then empty
   else "kept must be refs/crucible/moved/<effort folder name>/<name>/<n>" end)
