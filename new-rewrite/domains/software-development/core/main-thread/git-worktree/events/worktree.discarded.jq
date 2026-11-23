# worktree.discarded: a live tree's uncommitted changes cleared by
# worktree-discard.sh, {name, kept, signed}: the ref they are kept under,
# and whether the keeping commit carries a signature.
# Whether name is a live tree is worktree-discard.sh's question to
# worktree-trees.sh; this rule never replays the trees.
.event as $e | $e.body as $b
| (if $e.by == "worktree-discard.sh" then empty else "worktree.discarded is written only by worktree-discard.sh" end),
  ((($b | keys) - ["name", "kept", "signed"])[] | "\(.) is not a worktree.discarded field"),
  (if ($b.name | type) == "string" then empty else "name must be a tree's name" end),
  (if ($b.kept | type) == "string" and ($b.kept | test("^refs/crucible/discarded/[^/]+/[^/]+/[1-9][0-9]*$"))
	and ($b.kept | split("/")[4]) == $b.name
   then empty else "kept must be refs/crucible/discarded/<effort folder name>/<name>/<n>" end),
  (if ($b.signed | type) == "boolean" then empty else "signed must be a boolean" end)
