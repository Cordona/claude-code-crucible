# remote-review.fetched: the review threads of one fetched change, as its
# host gave them, written by review-fetch.sh. {change, head, threads, bots,
# report {path, sha256}}: change the seq of its remote-change.fetched; head
# the change's head when the threads were read; threads how many; bots the
# accounts the human named as AI; report pins the threads at
# reports/remote-review/<this event's seq>.json. Whether a thread is new is
# the reader's to work out against an earlier fetch; this one keeps no memory.
.event as $e | $e.body as $b | .prior as $all
| (if $e.by == "review-fetch.sh" then empty else "remote-review.fetched is written only by review-fetch.sh" end),
  ((($b | keys) - ["change", "head", "threads", "bots", "report"])[] | "\(.) is not a remote-review.fetched field"),
  (if ($b.change | type) == "number" and ([$all[] | select(.seq == $b.change and .type == "remote-change.fetched")] | length) == 1
   then empty else "change must be the seq of a remote-change.fetched" end),
  (if ($b.head | type) == "string" and ($b.head | test("^[0-9a-f]{40}([0-9a-f]{24})?$")) then empty
   else "head must be a full commit sha" end),
  (if ($b.threads | type) == "number" and $b.threads >= 0 and $b.threads == ($b.threads | floor) then empty
   else "threads must be how many threads, a whole number" end),
  (if ($b.bots | type) == "array" and all($b.bots[]; type == "string" and test("^[A-Za-z0-9._-]+(\\[bot\\])?$")) then empty
   else "bots must be a list of account names" end),
  (if ($b.report | type) == "object" and ($b.report | keys) == ["path", "sha256"]
	and $b.report.path == "reports/remote-review/\($e.seq).json"
	and ($b.report.sha256 | type) == "string" and ($b.report.sha256 | test("^[0-9a-f]{64}$")) then empty
   else "report must be {path: \"reports/remote-review/\($e.seq).json\", sha256: the file's sha256}" end)
