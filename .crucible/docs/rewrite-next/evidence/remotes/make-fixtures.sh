#!/bin/sh
# Derives the gh stub's replies from the owner's scrubbed GitHub samples
# (fixtures/github, from commit 6352454). The scrub gave every GraphQL id one
# filler, so this makes the ids unique (PRRT_n, PRR_n, IC_n) and links each
# thread to a review: that link is synthetic, not from GitHub. Everything
# else is the samples' own shape.
set -eu
E=$(cd -- "$(dirname -- "$0")" && pwd)
F="${E}/fixtures/github" S="${E}/stub-replies"
rm -rf -- "${S}"
mkdir -p "${S}"

# The PR object (REST).
cp "${F}/rest-pull-mergeable-blocked.json" "${S}/pull.json"
cp "${F}/rest-pull-mergeable-clean.json" "${S}/pull-closed.json"
cp "${F}/rest-pull-mergeable-unknown.json" "${S}/pull-merged.json"

# One page of threads and one of reviews, ids made unique; thread n's
# comments belong to review n (a review by the same kind of author where
# there is one).
jq '.data.repository.pullRequest |= (
	.reviews.nodes |= [to_entries[] | .value + {id: "PRR_\(.key)"}]
	| .reviewThreads.nodes |= [to_entries[] | .key as $n | .value + {id: "PRRT_\($n)"}
		| .comments.nodes |= map(.pullRequestReview.id = "PRR_\($n)")])' \
	"${F}/graphql-pull-review-threads-and-reviews.json" >"${S}/page.json"
jq -s '.' "${S}/page.json" >"${S}/threads.json"
cp "${S}/threads.json" "${S}/reviews.json"

# The threads over two pages, as --paginate --slurp gives them.
jq '[(.data.repository.pullRequest.reviewThreads |= (.nodes |= .[:5] | .pageInfo.hasNextPage = true)),
     (.data.repository.pullRequest.reviewThreads |= (.nodes |= .[5:]))]' "${S}/page.json" >"${S}/threads-paged.json"

# A thread whose comments run past one page.
jq '[.data.repository.pullRequest.reviewThreads.nodes[0].comments.pageInfo.hasNextPage = true]' "${S}/page.json" >"${S}/threads-incomplete.json"

# The single-thread samples (node queries), each as the only thread of a
# page: outdated, multi-line, resolved, unresolved, opened by a bot.
for v in outdated multiline-range resolved unresolved bot-author; do
	jq --slurpfile t "${F}/graphql-review-thread-${v}.json" \
		'[.data.repository.pullRequest.reviewThreads.nodes = [$t[0].data.node + {id: "PRRT_x"}
			| .comments.nodes |= map(.pullRequestReview.id = "PRR_0")]]' "${S}/page.json" >"${S}/threads-${v}.json"
done

# Not in the samples, made from the unresolved one: the left side, a file comment.
jq '.[0].data.repository.pullRequest.reviewThreads.nodes[0].diffSide = "LEFT"' "${S}/threads-unresolved.json" >"${S}/threads-left.json"
jq '.[0].data.repository.pullRequest.reviewThreads.nodes[0] |= (.subjectType = "FILE" | .line = null | .originalLine = null)' \
	"${S}/threads-unresolved.json" >"${S}/threads-file.json"

# Conversation comments (REST), one page, ids made unique.
jq '[[to_entries[] | .value + {node_id: "IC_\(.key)"}]]' "${F}/rest-issue-comments-list.json" >"${S}/comments.json"

# GraphQL NOT_FOUND, as a slurped page.
jq -s '.' "${F}/graphql-error-pull-not-found.json" >"${S}/notfound.json"
echo "stub replies in ${S}"
