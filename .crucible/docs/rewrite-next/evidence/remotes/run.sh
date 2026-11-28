#!/bin/sh
# Evidence run for remotes' read scripts on GitHub: change-read.sh and
# review-read.sh against a gh stub that replays the owner's scrubbed samples
# (make-fixtures.sh). Each check states what it expects; the run ends with
# the count. What a stub can't prove: that the query sent brings this reply
# back, and real paging.
set -u
R=/Users/cordona/IdeaProjects/cordona/claude-code-crucible/new-rewrite/domains/software-development/core/main-thread/remotes/scripts/internal
E=$(cd -- "$(dirname -- "$0")" && pwd)
sh "${E}/make-fixtures.sh" >/dev/null
export STUB_REPLIES="${E}/stub-replies" STUB_LOG="${E}/stub.log"
PATH="${E}/stubs:${PATH}"
export PATH
: >"${STUB_LOG}"
U=https://github.com/example-org/example-repo/pull/8
pass=0 fail=0
check() {
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1"; echo "      got:  $2"; echo "      want: $3"; fi
}
run() { out=$("$@" 2>"${E}/err"); rc=$?; err=$(cat "${E}/err"); }
F="${E}/fixtures/github"
P="${F}/graphql-pull-review-threads-and-reviews.json"

echo "=== change-read.sh: the PR object"
run sh "$R/change-read.sh" --url "$U"
check "reads: exit 0" "$rc" 0
check "the change's fields from repos/O/R/pulls/N" "$(printf '%s' "$out" | jq -c '{host, project, number, author, base_branch, state}')" \
	'{"host":"github","project":"example-org/example-repo","number":8,"author":"example-user-2","base_branch":"example-branch","state":"open"}'
check "head is the PR's head sha" "$(printf '%s' "$out" | jq -r .head)" "$(jq -r .head.sha "${F}/rest-pull-mergeable-blocked.json")"
check "title and description are the PR's own" "$(printf '%s' "$out" | jq -c '[.title, .description]')" "$(jq -c '[.title, .body]' "${F}/rest-pull-mergeable-blocked.json")"
check "the call asked for the PR" "$(tail -1 "${STUB_LOG}")" 'api repos/example-org/example-repo/pulls/8'
run env STUB_PULL=pull-closed.json sh "$R/change-read.sh" --url "$U"
check "a closed, unmerged PR: state closed" "$(printf '%s' "$out" | jq -r .state)" closed
run env STUB_PULL=pull-merged.json sh "$R/change-read.sh" --url "$U"
check "a merged PR (state closed, merged true): state merged" "$(printf '%s' "$out" | jq -r .state)" merged
run env STUB_FAIL=pull sh "$R/change-read.sh" --url "$U"
check "a 404: exit 1, gh's error on stderr" "$rc:$(printf '%s' "$err" | grep -c 'Not Found (HTTP 404)')" '1:1'
run sh "$R/change-read.sh" --url https://github.com/example-org/example-repo/issues/8
check "an issue link: exit 3" "$rc" 3
run sh "$R/change-read.sh" --url 'https://github.com/o/r/pull/8;rm'
check "an unsafe link: exit 2" "$rc" 2

echo "=== review-read.sh: the whole review of one PR"
run sh "$R/review-read.sh" --url "$U"
check "reads: exit 0" "$rc" 0
want_threads=$(jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select([.comments.nodes[] | select(.body != "")] | length > 0)] | length' "$P")
want_reviews=$(jq '[.data.repository.pullRequest.reviews.nodes[] | select(.body != "" and .state != "DISMISSED")] | length' "$P")
want_comments=$(jq '[.[] | select(.body != "")] | length' "${F}/rest-issue-comments-list.json")
check "line threads, then reviews with a body, then conversation comments" \
	"$(printf '%s' "$out" | jq -c '[.threads[] | .id | sub("_[0-9]+$"; "")] | group_by(.) | map({(.[0]): length}) | add')" \
	"$(jq -cn --argjson t "$want_threads" --argjson r "$want_reviews" --argjson c "$want_comments" '{IC: $c, PRR: $r, PRRT: $t}')"
check "empty-body reviews (implicit, approvals) left out: $(jq '[.data.repository.pullRequest.reviews.nodes[] | select(.body == "")] | length' "$P") of them" \
	"$(printf '%s' "$out" | jq '[.threads[] | select(.id | startswith("PRR_")) | .comments[0].body | select(. == "")] | length')" 0
check "a line thread: new_line is originalLine on the RIGHT side, path kept" \
	"$(printf '%s' "$out" | jq -c '.threads[0] | {path, new_line, old: has("old_line")}')" \
	"$(jq -c '.data.repository.pullRequest.reviewThreads.nodes[0] | {path, new_line: .originalLine, old: false}' "$P")"
check "a line thread's resolved is isResolved" "$(printf '%s' "$out" | jq -c '[.threads[] | select(.id | startswith("PRRT_")) | .resolved]')" \
	"$(jq -c '[.data.repository.pullRequest.reviewThreads.nodes[] | .isResolved]' "$P")"
check "a line thread's commit is its review's commit.oid" "$(printf '%s' "$out" | jq -r '.threads[2].commit')" \
	"$(jq -r '.data.repository.pullRequest.reviews.nodes[2].commit.oid' "$P")"
check "a review's commit is its own commit.oid; resolved false" "$(printf '%s' "$out" | jq -c '[.threads[] | select(.id | startswith("PRR_"))][0] | {commit, resolved}')" \
	"$(jq -c '[.data.repository.pullRequest.reviews.nodes[] | select(.body != "")][0] | {commit: .commit.oid, resolved: false}' "$P")"
check "a conversation comment has no commit" "$(printf '%s' "$out" | jq '[.threads[] | select(.id | startswith("IC_")) | has("commit")] | any')" false
check "bots by the host: GraphQL __typename and REST type Bot" \
	"$(printf '%s' "$out" | jq -c '[.threads[] | .comments[] | .source] | group_by(.) | map({(.[0]): length}) | add')" \
	"$(jq -cn --slurpfile p "$P" --slurpfile c "${F}/rest-issue-comments-list.json" '
		[($p[0].data.repository.pullRequest | (.reviewThreads.nodes[].comments.nodes[] | select(.body != "") | .author.__typename),
		  (.reviews.nodes[] | select(.body != "" and .state != "DISMISSED") | .author.__typename)),
		 ($c[0][] | select(.body != "") | .user.type)]
		| map(if . == "Bot" then "bot" else "human" end) | group_by(.) | map({(.[0]): length}) | add')"
check "role author: comments by the PR's author" \
	"$(printf '%s' "$out" | jq '[.threads[] | .comments[] | select(.role == "author")] | length')" \
	"$(jq -n --slurpfile p "$P" --slurpfile c "${F}/rest-issue-comments-list.json" '$p[0].data.repository.pullRequest as $pr | $pr.author.login as $a
		| [($pr.reviewThreads.nodes[].comments.nodes[] | select(.body != "") | .author.login),
		   ($pr.reviews.nodes[] | select(.body != "" and .state != "DISMISSED") | .author.login),
		   ($c[0][] | select(.body != "") | .user.login)] | map(select(. == $a)) | length')"
check "replies stay in their thread, oldest first, with id and updated" \
	"$(printf '%s' "$out" | jq -c '.threads[0].comments | map({id, updated})')" \
	"$(jq -c '.data.repository.pullRequest.reviewThreads.nodes[0].comments.nodes | map({id: (.databaseId | tostring), updated: .updatedAt})' "$P")"
check "the calls: threads, reviews (GraphQL, all pages) and the comments (REST, all pages)" \
	"$(grep -c -- '--paginate --slurp' "${STUB_LOG}"):$(grep -c 'number=8' "${STUB_LOG}"):$(grep -c 'issues/8/comments?per_page=100' "${STUB_LOG}")" '3:2:1'

echo "=== review-read.sh: the single-thread samples"
for v in outdated:8:false multiline-range:4:true resolved:5:true unresolved:3:false; do
	name=${v%%:*} rest=${v#*:} line=${rest%%:*} res=${rest#*:}
	run env STUB_THREADS="threads-${name}.json" sh "$R/review-read.sh" --url "$U"
	check "${name}: new_line is originalLine ${line}, resolved ${res}" "$(printf '%s' "$out" | jq -c '.threads[0] | [.new_line, .resolved]')" "[${line},${res}]"
done
run env STUB_THREADS=threads-bot-author.json sh "$R/review-read.sh" --url "$U"
check "a thread opened by the Copilot reviewer (GraphQL login, no [bot]): source bot" "$(printf '%s' "$out" | jq -r '.threads[0].comments[0].source')" bot
run env STUB_THREADS=threads-left.json sh "$R/review-read.sh" --url "$U"
check "the LEFT side gives old_line, not new_line" "$(printf '%s' "$out" | jq -c '.threads[0] | [.old_line, has("new_line")]')" '[3,false]'
run env STUB_THREADS=threads-file.json sh "$R/review-read.sh" --url "$U"
check "a file comment: path, no line" "$(printf '%s' "$out" | jq -c '.threads[0] | [(.path | type), has("new_line"), has("old_line")]')" '["string",false,false]'

echo "=== review-read.sh: paging, incomplete, errors, bots named"
run sh "$R/review-read.sh" --url "$U"; one=$out
run env STUB_THREADS=threads-paged.json sh "$R/review-read.sh" --url "$U"
check "threads over two pages read as one" "$out" "$one"
run env STUB_THREADS=threads-incomplete.json sh "$R/review-read.sh" --url "$U"
check "a thread with more than 100 comments: exit 1, nothing printed" "$rc:$out:$(printf '%s' "$err" | grep -c 'more than 100 comments')" '1::1'
run env STUB_THREADS=notfound.json sh "$R/review-read.sh" --url "$U"
check "GraphQL NOT_FOUND (HTTP 200): exit 1, its message on stderr" "$rc:$(printf '%s' "$err" | grep -c 'Could not resolve')" '1:1'
run env STUB_FAIL=comments sh "$R/review-read.sh" --url "$U"
check "a failed comments call: exit 1, nothing printed" "$rc:$out" '1:'
run sh "$R/review-read.sh" --url "$U" --bot example-user-9
check "--bot names a human account as AI" "$(printf '%s' "$out" | jq -c '[.threads[] | .comments[] | select(.source == "bot")] | length > 0')" true
run sh "$R/review-read.sh" --url "$U" --bot 'x;y'
check "--bot with a non-name: exit 2" "$rc" 2

echo "=== GitLab, on hand-written fixtures in the shape the live reads showed"
export STUB_GITLAB="${E}/fixtures/gitlab"
GU=https://gitlab.example.test/group/sub/app/-/merge_requests/42
run sh "$R/change-read.sh" --url "$GU"
check "an MR: project path with subgroups, state opened is open, base_sha from diff_refs" \
	"$(printf '%s' "$out" | jq -c '{host, project, number, author, state, base_sha: .base_sha[0:4], head: .head[0:4], base_branch}')" \
	'{"host":"gitlab","project":"group/sub/app","number":42,"author":"fixer","state":"open","base_sha":"1111","head":"2222","base_branch":"main"}'
check "the call names the host and the project as one segment" "$(tail -1 "${STUB_LOG}")" 'api --hostname gitlab.example.test projects/group%2Fsub%2Fapp/merge_requests/42'
run env STUB_FAIL=mr sh "$R/change-read.sh" --url "$GU"
check "a failed MR call: exit 1, glab's error on stderr" "$rc:$(printf '%s' "$err" | grep -c '404 Not Found')" '1:1'
run sh "$R/change-read.sh" --url https://gitlab.example.test:8443/g/p/-/merge_requests/1
check "a GitLab host with a port: exit 3" "$rc" 3
: >"${STUB_LOG}"
run sh "$R/review-read.sh" --url "$GU" --bot review-bot
check "system notes and empty bodies left out; every other discussion kept, in order" "$(printf '%s' "$out" | jq -c '[.threads[].id]')" '["d-bot","d-reply","d-line","d-removed","d-resolved"]'
check "--bot names the AI reviewer; everyone else human" "$(printf '%s' "$out" | jq -c '[.threads[] | .comments[] | .source] | unique')" '["bot","human"]'
check "role author for the MR's author (the fixer), in a thread and on its own" "$(printf '%s' "$out" | jq -c '[.threads[] | [.comments[].role] | join(",")]')" '["reviewer","author","reviewer,author","reviewer","reviewer"]'
check "a note with no position: the head of the latest version before it" "$(printf '%s' "$out" | jq -c '[.threads[0,1] | .commit[0:4]]')" '["3333","2222"]'
check "a line comment: its position's head_sha, path and new_line" "$(printf '%s' "$out" | jq -c '.threads[2] | {commit: .commit[0:4], path, new_line, old: has("old_line")}')" '{"commit":"3333","path":"src/retry.sh","new_line":17,"old":false}'
check "a comment on a removed line: old_line, no new_line" "$(printf '%s' "$out" | jq -c '.threads[3] | [.old_line, has("new_line")]')" '[9,false]'
check "resolved threads kept and flagged; plain notes not resolvable, false" "$(printf '%s' "$out" | jq -c '[.threads[].resolved]')" '[false,false,false,false,true]'
check "each comment: its note id and updated_at (moved on resolve)" "$(printf '%s' "$out" | jq -c '.threads[4].comments[0] | {id, updated}')" '{"id":"7","updated":"2026-11-02T10:00:00.000Z"}'
check "the calls: the MR, its discussions and versions, all pages" "$(grep -c -- '--paginate' "${STUB_LOG}"):$(grep -c 'discussions?per_page=100' "${STUB_LOG}"):$(grep -c 'versions?per_page=100' "${STUB_LOG}")" '2:1:1'
run sh "$R/review-read.sh" --url "$GU"
check "no --bot: every GitLab author is human" "$(printf '%s' "$out" | jq -c '[.threads[] | .comments[] | .source] | unique')" '["human"]'

echo
echo "passed ${pass}, failed ${fail}"
rm -f -- "${E}/err"
[ "${fail}" -eq 0 ]
