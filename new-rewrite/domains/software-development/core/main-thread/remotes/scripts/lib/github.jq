# GitHub's replies in the common shapes, a jq module: load it with
# jq -L <this folder> and include "github". Each def says its input.

def gh_bot($bots): (.__typename // .type) == "Bot" or ((.login // "") as $l | $bots | index([$l]) != null);
def gh_comment($author; $bots; $id; $who; $body; $updated):
	{id: ($id | tostring),
	 source: (if $who != null and ($who | gh_bot($bots)) then "bot" else "human" end),
	 role: (if $who != null and $who.login == $author then "author" else "reviewer" end),
	 updated: $updated, body: $body};

# Input: repos/O/R/pulls/N. The change as change-read.sh prints it.
def gh_change:
	{author: .user.login, head: .head.sha, base_sha: .base.sha, base_branch: .base.ref, title, description: (.body // ""),
	 state: (if .merged == true then "merged" elif .state == "open" then "open" else "closed" end)};

# Input {pages, reviews, comments, bots}: pages the review-threads query's
# pages, reviews the reviews query's pages, comments the conversation
# comments' pages (REST, slurped), bots the names the human gave.
# Output {threads}: line threads, then review summaries with a body, not
# dismissed, then conversation comments.
def gh_threads:
	.bots as $bots
	| (.pages[0].data.repository.pullRequest.author.login) as $author
	| [.reviews[].data.repository.pullRequest.reviews.nodes[]] as $reviews
	| ($reviews | map({key: .id, value: .commit.oid}) | from_entries) as $commit_of
	| {threads: (
		[.pages[].data.repository.pullRequest.reviewThreads.nodes[]
		 | (.comments.nodes[0].pullRequestReview.id // null) as $r
		 | {id, resolved: .isResolved}
		   + (if $r != null and $commit_of[$r] != null then {commit: $commit_of[$r]} else {} end)
		   + (if .subjectType == "FILE" then {path}
		      elif .diffSide == "LEFT" then {path, old_line: .originalLine}
		      else {path, new_line: .originalLine} end)
		   + {comments: [.comments.nodes[] | select((.body // "") != "")
			| gh_comment($author; $bots; .databaseId; .author; .body; .updatedAt)]}
		 | select(.comments | length > 0)]
		+ [$reviews[] | select((.body // "") != "" and .state != "DISMISSED")
		   | {id, resolved: false, commit: .commit.oid,
		      comments: [gh_comment($author; $bots; .databaseId; .author; .body; .updatedAt)]}]
		+ [.comments[][] | select((.body // "") != "")
		   | {id: .node_id, resolved: false,
		      comments: [gh_comment($author; $bots; .id; .user; .body; .updated_at)]}])};

# Input: the review-threads query's pages. The faults that make a read
# incomplete: a thread with more comments than one page holds.
def gh_incomplete:
	[.[].data.repository.pullRequest.reviewThreads.nodes[] | select(.comments.pageInfo.hasNextPage) | .id]
	| if length > 0 then "threads \(join(", ")) have more than 100 comments" else empty end;
