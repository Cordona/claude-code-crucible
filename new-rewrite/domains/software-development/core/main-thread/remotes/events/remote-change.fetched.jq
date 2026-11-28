# remote-change.fetched: one pull or merge request read from its host and its
# commits fetched, written by change-fetch.sh. {host, url, repo, number,
# base, head, author, report {path, sha256}}: host github or gitlab; repo the
# repository the commits are in; base the merge base, head the change's head;
# report pins the author's text (title, description, base branch, state) at
# reports/remote-change/<this event's seq>.json.
.event as $e | $e.body as $b
| (if $e.by == "change-fetch.sh" then empty else "remote-change.fetched is written only by change-fetch.sh" end),
  ((($b | keys) - ["host", "url", "repo", "number", "base", "head", "author", "report"])[] | "\(.) is not a remote-change.fetched field"),
  (if $b.host == "github" then
	(if ($b.url | type) == "string" and ($b.url | test("^https://github\\.com/[^/]+/[^/]+/pull/[1-9][0-9]*$")) then empty
	 else "url must be https://github.com/OWNER/REPO/pull/N" end)
   elif $b.host == "gitlab" then
	(if ($b.url | type) == "string" and ($b.url | test("^https://[a-z0-9.-]+/[^/]+(/[^/]+)+/-/merge_requests/[1-9][0-9]*$")) then empty
	 else "url must be https://HOST/PROJECT/-/merge_requests/N" end)
   else "host must be github or gitlab" end),
  (if ($b.number | type) == "number" and ($b.url | type) == "string" and ($b.url | endswith("/\($b.number)")) then empty
   else "number must be the change's number, as its url ends" end),
  (if ($b.repo | type) == "string" and ($b.repo | startswith("/")) then empty else "repo must be an absolute folder" end),
  ($b.base, $b.head | if type == "string" and test("^[0-9a-f]{40}([0-9a-f]{24})?$") then empty
   else "base and head must be full commit shas" end),
  (if ($b.author | type) == "string" and ($b.author | test("^[^[:space:][:cntrl:]]+$")) then empty
   else "author must be the change's author's account name" end),
  (if ($b.report | type) == "object" and ($b.report | keys) == ["path", "sha256"]
	and $b.report.path == "reports/remote-change/\($e.seq).json"
	and ($b.report.sha256 | type) == "string" and ($b.report.sha256 | test("^[0-9a-f]{64}$")) then empty
   else "report must be {path: \"reports/remote-change/\($e.seq).json\", sha256: the file's sha256}" end)
