# worktree.synced: what worktree-catch-up.sh did with a commit and a live
# tree, {name, with, result, commit?, signed?}: result in_sync, merged,
# conflict or aborted; commit and signed for merged only.
# Whether name is a live tree is worktree-catch-up.sh's question to
# worktree-trees.sh; this rule never replays the trees.
def sha: type == "string" and test("^[0-9a-f]{40}([0-9a-f]{24})?$");
.event as $e | $e.body as $b
| (if $e.by == "worktree-catch-up.sh" then empty else "worktree.synced is written only by worktree-catch-up.sh" end),
  ((($b | keys) - ["name", "with", "result", "commit", "signed"])[] | "\(.) is not a worktree.synced field"),
  (if ($b.name | type) == "string" then empty else "name must be a tree's name" end),
  (if $b.with | sha then empty else "with must be a full commit sha" end),
  (if $b.result == "merged" then
		(if ($b.commit | sha) and ($b.signed | type) == "boolean" then empty
		 else "a merged sync carries commit, a full sha, and signed, a boolean" end)
   elif ($b.result | IN("in_sync", "conflict", "aborted")) then
		(if ($b | has("commit")) or ($b | has("signed")) then "only a merged sync carries commit and signed" else empty end)
   else "result must be in_sync, merged, conflict or aborted" end)
