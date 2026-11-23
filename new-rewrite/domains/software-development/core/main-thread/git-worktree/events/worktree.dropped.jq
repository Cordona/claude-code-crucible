# worktree.dropped: a live tree removed by worktree-drop.sh, {name, answer?}:
# answer the seq of the human's recorded yes when the drop needed one, used
# once. Whether it is a yes is worktree-drop.sh's question to the gate's
# reader, and whether name is a live tree its question to worktree-trees.sh;
# this rule never reads the gate's events or replays the trees.
.event as $e | $e.body as $b | .prior as $all
| (if $e.by == "worktree-drop.sh" then empty else "worktree.dropped is written only by worktree-drop.sh" end),
  ((($b | keys) - ["name", "answer"])[] | "\(.) is not a worktree.dropped field"),
  (if ($b.name | type) == "string" then empty else "name must be a tree's name" end),
  (if $b | has("answer") | not then empty
   elif ($b.answer | type) != "number" then "answer must be the seq of the human's recorded yes"
   elif ([$all[] | select(.type == "worktree.dropped" and .body.answer == $b.answer)] | length) > 0
	then "answer \($b.answer) already dropped a tree"
   else empty end)
