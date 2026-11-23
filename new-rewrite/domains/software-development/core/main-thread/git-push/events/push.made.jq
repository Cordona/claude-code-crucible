# push.made: a live tree's branch tip pushed by push-tree.sh, {name, remote,
# commit, answer}: the tree, the remote's name, the commit pushed, and the
# seq of the human's recorded yes, used once. Whether it is a yes is
# push-tree.sh's question to the gate's reader, and whether name is a live
# tree its question to git-worktree's worktree-trees.sh; this rule never
# reads the gate's events or replays the trees. Any effort state is fine, so
# a closed effort's tree can still go public.
.event as $e | $e.body as $b | .prior as $all
| (if $e.by == "push-tree.sh" then empty else "push.made is written only by push-tree.sh" end),
  ((($b | keys) - ["name", "remote", "commit", "answer"])[] | "\(.) is not a push.made field"),
  (if ($b.name | type) == "string" then empty else "name must be a tree's name" end),
  (if ($b.remote | type) == "string" and ($b.remote | test("^[^-[:space:][:cntrl:]][^[:space:][:cntrl:]]*$")) then empty
   else "remote must be a remote's name" end),
  (if ($b.commit | type) == "string" and ($b.commit | test("^[0-9a-f]{40}([0-9a-f]{24})?$")) then empty
   else "commit must be a full commit sha" end),
  (if ($b.answer | type) != "number" then "answer must be the seq of the human's recorded yes"
   elif ([$all[] | select(.type == "push.made" and .body.answer == $b.answer)] | length) > 0
	then "answer \($b.answer) already pushed"
   else empty end)
