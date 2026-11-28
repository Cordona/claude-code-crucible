# mount.undone: a mount taken out of the human's checkout by mount-undo.sh,
# {repo, forgotten}: forgotten true when the human had committed it and only
# its record went. The effort made a mount in that repository before.
.event as $e | $e.body as $b | .prior as $all
| (if $e.by == "mount-undo.sh" then empty else "mount.undone is written only by mount-undo.sh" end),
  ((($b | keys) - ["repo", "forgotten"])[] | "\(.) is not a mount.undone field"),
  (if ($b.repo | type) == "string" and ($b.repo | startswith("/")) then
		(if any($all[]; .type == "mount.made" and .body.repo == $b.repo) then empty
		 else "the effort made no mount in \($b.repo)" end)
   else "repo must be an absolute folder" end),
  (if ($b.forgotten | type) == "boolean" then empty else "forgotten must be a boolean" end)
