# Field map per endpoint

Built from all scrubbed samples listed in index.md (the scrubbed files keep the source key paths and types exactly). `[]` marks array elements. *Presence* is counted over the objects of that path across all samples of the endpoint; `optional` means the key was missing in some of them. Enum values are the real values observed.

## GET /repos/{owner}/{repo}/commits/{sha}/check-runs

Samples: `extra-check-runs-for-head.json`

| Key path | JSON type(s) | Nullable | Presence | Enum values seen | Only in samples |
|---|---|---|---|---|---|
| `check_runs` | array | no | always |  |  |
| `check_runs[].app` | object | no | always |  |  |
| `check_runs[].app.client_id` | string | no | always |  |  |
| `check_runs[].app.created_at` | string | no | always |  |  |
| `check_runs[].app.description` | string | no | always |  |  |
| `check_runs[].app.events` | array | no | always |  | array of App event names |
| `check_runs[].app.external_url` | string | no | always |  |  |
| `check_runs[].app.html_url` | string | no | always |  |  |
| `check_runs[].app.id` | integer | no | always |  |  |
| `check_runs[].app.name` | string | no | always |  |  |
| `check_runs[].app.node_id` | string | no | always |  |  |
| `check_runs[].app.owner` | object | no | always |  | simple-user object, see bottom |
| `check_runs[].app.permissions` | object | no | always |  | App permission map (name -> read/write) |
| `check_runs[].app.slug` | string | no | always |  |  |
| `check_runs[].app.updated_at` | string | no | always |  |  |
| `check_runs[].check_suite` | object | no | always |  |  |
| `check_runs[].check_suite.id` | integer | no | always |  |  |
| `check_runs[].completed_at` | string | no | always |  |  |
| `check_runs[].conclusion` | string | no | always | success |  |
| `check_runs[].details_url` | string | no | always |  |  |
| `check_runs[].external_id` | string | no | always |  |  |
| `check_runs[].head_sha` | string | no | always |  |  |
| `check_runs[].html_url` | string | no | always |  |  |
| `check_runs[].id` | integer | no | always |  |  |
| `check_runs[].name` | string | no | always |  |  |
| `check_runs[].node_id` | string | no | always |  |  |
| `check_runs[].output` | object | no | always |  |  |
| `check_runs[].output.annotations_count` | integer | no | always |  |  |
| `check_runs[].output.annotations_url` | string | no | always |  |  |
| `check_runs[].output.summary` | null | yes | always |  |  |
| `check_runs[].output.text` | null | yes | always |  |  |
| `check_runs[].output.title` | null | yes | always |  |  |
| `check_runs[].pull_requests` | array | no | always |  |  |
| `check_runs[].started_at` | string | no | always |  |  |
| `check_runs[].status` | string | no | always | completed |  |
| `check_runs[].url` | string | no | always |  |  |
| `total_count` | integer | no | always |  |  |

## GET /repos/{owner}/{repo}/issues/comments/{comment_id}

Samples: `rest-issue-comment-app-bot.json`, `rest-issue-comment-contributor-association.json`, `rest-issue-comment-github-actions-bot.json`, `rest-issue-comment-human.json`, `rest-issue-comment-pr-author-summary.json`, `media-issue-comment-default.json`, `media-issue-comment-raw.json`, `media-issue-comment-text.json`, `media-issue-comment-html.json`, `media-issue-comment-full.json`, `media-issue-comment-noaccept.json`

| Key path | JSON type(s) | Nullable | Presence | Enum values seen | Only in samples |
|---|---|---|---|---|---|
| `author_association` | string | no | always | CONTRIBUTOR, MEMBER, NONE |  |
| `body` | string | no | optional (9/11) |  |  |
| `body_html` | string | no | optional (2/11) |  | media-issue-comment-full, media-issue-comment-html |
| `body_text` | string | no | optional (2/11) |  | media-issue-comment-full, media-issue-comment-text |
| `created_at` | string | no | always |  |  |
| `html_url` | string | no | always |  |  |
| `id` | integer | no | always |  |  |
| `issue_url` | string | no | always |  |  |
| `minimized` | null | yes | always |  |  |
| `node_id` | string | no | always |  |  |
| `performed_via_github_app` | object | yes | always |  |  |
| `performed_via_github_app.created_at` | string | no | always |  |  |
| `performed_via_github_app.description` | string | no | always |  |  |
| `performed_via_github_app.events` | array | no | always |  | array of App event names |
| `performed_via_github_app.external_url` | string | no | always |  |  |
| `performed_via_github_app.html_url` | string | no | always |  |  |
| `performed_via_github_app.id` | integer | no | always |  |  |
| `performed_via_github_app.name` | string | no | always |  |  |
| `performed_via_github_app.node_id` | string | no | always |  |  |
| `performed_via_github_app.owner` | object | no | always |  | simple-user object, see bottom |
| `performed_via_github_app.permissions` | object | no | always |  | App permission map (name -> read/write) |
| `performed_via_github_app.slug` | string | no | always |  |  |
| `performed_via_github_app.updated_at` | string | no | always |  |  |
| `pin` | null | yes | always |  |  |
| `reactions` | object | no | always |  |  |
| `reactions.+1` | integer | no | always |  |  |
| `reactions.-1` | integer | no | always |  |  |
| `reactions.confused` | integer | no | always |  |  |
| `reactions.eyes` | integer | no | always |  |  |
| `reactions.heart` | integer | no | always |  |  |
| `reactions.hooray` | integer | no | always |  |  |
| `reactions.laugh` | integer | no | always |  |  |
| `reactions.rocket` | integer | no | always |  |  |
| `reactions.total_count` | integer | no | always |  |  |
| `reactions.url` | string | no | always |  |  |
| `updated_at` | string | no | always |  |  |
| `url` | string | no | always |  |  |
| `user` | object | no | always |  | simple-user object, see bottom |

## GET /repos/{owner}/{repo}/issues/{n}/comments

Samples: `rest-issue-comments-list.json`

| Key path | JSON type(s) | Nullable | Presence | Enum values seen | Only in samples |
|---|---|---|---|---|---|
| `[].author_association` | string | no | always | MEMBER, NONE |  |
| `[].body` | string | no | always |  |  |
| `[].created_at` | string | no | always |  |  |
| `[].html_url` | string | no | always |  |  |
| `[].id` | integer | no | always |  |  |
| `[].issue_url` | string | no | always |  |  |
| `[].minimized` | null | yes | always |  |  |
| `[].node_id` | string | no | always |  |  |
| `[].performed_via_github_app` | object | yes | always |  |  |
| `[].performed_via_github_app.client_id` | string | no | always |  |  |
| `[].performed_via_github_app.created_at` | string | no | always |  |  |
| `[].performed_via_github_app.description` | string | no | always |  |  |
| `[].performed_via_github_app.events` | array | no | always |  | array of App event names |
| `[].performed_via_github_app.external_url` | string | no | always |  |  |
| `[].performed_via_github_app.html_url` | string | no | always |  |  |
| `[].performed_via_github_app.id` | integer | no | always |  |  |
| `[].performed_via_github_app.name` | string | no | always |  |  |
| `[].performed_via_github_app.node_id` | string | no | always |  |  |
| `[].performed_via_github_app.owner` | object | no | always |  | simple-user object, see bottom |
| `[].performed_via_github_app.permissions` | object | no | always |  | App permission map (name -> read/write) |
| `[].performed_via_github_app.slug` | string | no | always |  |  |
| `[].performed_via_github_app.updated_at` | string | no | always |  |  |
| `[].reactions` | object | no | always |  |  |
| `[].reactions.+1` | integer | no | always |  |  |
| `[].reactions.-1` | integer | no | always |  |  |
| `[].reactions.confused` | integer | no | always |  |  |
| `[].reactions.eyes` | integer | no | always |  |  |
| `[].reactions.heart` | integer | no | always |  |  |
| `[].reactions.hooray` | integer | no | always |  |  |
| `[].reactions.laugh` | integer | no | always |  |  |
| `[].reactions.rocket` | integer | no | always |  |  |
| `[].reactions.total_count` | integer | no | always |  |  |
| `[].reactions.url` | string | no | always |  |  |
| `[].updated_at` | string | no | always |  |  |
| `[].url` | string | no | always |  |  |
| `[].user` | object | no | always |  | simple-user object, see bottom |

## GET /repos/{owner}/{repo}/pulls/comments/{comment_id}

Samples: `rest-review-comment-app-bot.json`, `rest-review-comment-author-reply.json`, `rest-review-comment-commit-moved.json`, `rest-review-comment-copilot-bot.json`, `rest-review-comment-copilot-sources.json`, `rest-review-comment-details-block.json`, `rest-review-comment-edited.json`, `rest-review-comment-image-or-link.json`, `rest-review-comment-mention.json`, `rest-review-comment-multiline.json`, `rest-review-comment-outdated.json`, `rest-review-comment-reactions.json`, `rest-review-comment-single-line.json`, `rest-review-comment-suggestion.json`, `media-review-comment-default.json`, `media-review-comment-raw.json`, `media-review-comment-text.json`, `media-review-comment-html.json`, `media-review-comment-full.json`, `media-review-comment-noaccept.json`

| Key path | JSON type(s) | Nullable | Presence | Enum values seen | Only in samples |
|---|---|---|---|---|---|
| `_links` | object | no | always |  |  |
| `_links.html` | object | no | always |  |  |
| `_links.html.href` | string | no | always |  |  |
| `_links.pull_request` | object | no | always |  |  |
| `_links.pull_request.href` | string | no | always |  |  |
| `_links.self` | object | no | always |  |  |
| `_links.self.href` | string | no | always |  |  |
| `author_association` | string | no | always | MEMBER, NONE |  |
| `body` | string | no | always |  |  |
| `body_html` | string | no | optional (2/20) |  | media-review-comment-full, media-review-comment-html |
| `body_text` | string | no | optional (2/20) |  | media-review-comment-full, media-review-comment-text |
| `commit_id` | string | no | always |  |  |
| `copilot_code_review_severity` | string | yes | always | high, low, medium |  |
| `copilot_code_review_sources` | array | no | always |  |  |
| `copilot_code_review_sources[].kind` | string | no | always | CUSTOM_INSTRUCTIONS |  |
| `copilot_code_review_sources[].name` | string | no | always |  |  |
| `copilot_code_review_sources[].path` | string | no | always |  |  |
| `created_at` | string | no | always |  |  |
| `diff_hunk` | string | no | always |  |  |
| `html_url` | string | no | always |  |  |
| `id` | integer | no | always |  |  |
| `in_reply_to_id` | integer | no | optional (3/20) |  | rest-review-comment-app-bot, rest-review-comment-author-reply, rest-review-comment-mention |
| `is_copilot_code_review` | boolean | no | always |  |  |
| `line` | integer | yes | always |  |  |
| `node_id` | string | no | always |  |  |
| `original_commit_id` | string | no | always |  |  |
| `original_line` | integer | no | always |  |  |
| `original_position` | integer | no | always |  |  |
| `original_start_line` | integer | yes | always |  |  |
| `path` | string | no | always |  |  |
| `position` | integer | no | always |  |  |
| `pull_request_review_id` | integer | no | always |  |  |
| `pull_request_url` | string | no | always |  |  |
| `reactions` | object | no | always |  |  |
| `reactions.+1` | integer | no | always |  |  |
| `reactions.-1` | integer | no | always |  |  |
| `reactions.confused` | integer | no | always |  |  |
| `reactions.eyes` | integer | no | always |  |  |
| `reactions.heart` | integer | no | always |  |  |
| `reactions.hooray` | integer | no | always |  |  |
| `reactions.laugh` | integer | no | always |  |  |
| `reactions.rocket` | integer | no | always |  |  |
| `reactions.total_count` | integer | no | always |  |  |
| `reactions.url` | string | no | always |  |  |
| `side` | string | no | always | RIGHT |  |
| `start_line` | integer | yes | always |  |  |
| `start_side` | string | yes | always | RIGHT |  |
| `subject_type` | string | no | always | line |  |
| `updated_at` | string | no | always |  |  |
| `url` | string | no | always |  |  |
| `user` | object | no | always |  | simple-user object, see bottom |

## GET /repos/{owner}/{repo}/pulls/comments/{comment_id} (error responses)

Samples: `error-404-review-comment-not-found.json`

| Key path | JSON type(s) | Nullable | Presence | Enum values seen | Only in samples |
|---|---|---|---|---|---|
| `documentation_url` | string | no | always |  |  |
| `message` | string | no | always |  |  |
| `status` | string | no | always | 404 |  |

## GET /repos/{owner}/{repo}/pulls/comments

Samples: `rest-repo-review-comments-list.json`

| Key path | JSON type(s) | Nullable | Presence | Enum values seen | Only in samples |
|---|---|---|---|---|---|
| `[]._links` | object | no | always |  |  |
| `[]._links.html` | object | no | always |  |  |
| `[]._links.html.href` | string | no | always |  |  |
| `[]._links.pull_request` | object | no | always |  |  |
| `[]._links.pull_request.href` | string | no | always |  |  |
| `[]._links.self` | object | no | always |  |  |
| `[]._links.self.href` | string | no | always |  |  |
| `[].author_association` | string | no | always | MEMBER, NONE |  |
| `[].body` | string | no | always |  |  |
| `[].commit_id` | string | no | always |  |  |
| `[].copilot_code_review_severity` | string | yes | always | high |  |
| `[].copilot_code_review_sources` | array | no | always |  |  |
| `[].created_at` | string | no | always |  |  |
| `[].diff_hunk` | string | no | always |  |  |
| `[].html_url` | string | no | always |  |  |
| `[].id` | integer | no | always |  |  |
| `[].in_reply_to_id` | integer | no | optional (1/2) |  |  |
| `[].is_copilot_code_review` | boolean | no | always |  |  |
| `[].line` | integer | no | always |  |  |
| `[].node_id` | string | no | always |  |  |
| `[].original_commit_id` | string | no | always |  |  |
| `[].original_line` | integer | no | always |  |  |
| `[].original_position` | integer | no | always |  |  |
| `[].original_start_line` | integer | no | always |  |  |
| `[].path` | string | no | always |  |  |
| `[].position` | integer | no | always |  |  |
| `[].pull_request_review_id` | integer | no | always |  |  |
| `[].pull_request_url` | string | no | always |  |  |
| `[].reactions` | object | no | always |  |  |
| `[].reactions.+1` | integer | no | always |  |  |
| `[].reactions.-1` | integer | no | always |  |  |
| `[].reactions.confused` | integer | no | always |  |  |
| `[].reactions.eyes` | integer | no | always |  |  |
| `[].reactions.heart` | integer | no | always |  |  |
| `[].reactions.hooray` | integer | no | always |  |  |
| `[].reactions.laugh` | integer | no | always |  |  |
| `[].reactions.rocket` | integer | no | always |  |  |
| `[].reactions.total_count` | integer | no | always |  |  |
| `[].reactions.url` | string | no | always |  |  |
| `[].side` | string | no | always | RIGHT |  |
| `[].start_line` | integer | no | always |  |  |
| `[].start_side` | string | no | always | RIGHT |  |
| `[].subject_type` | string | no | always | line |  |
| `[].updated_at` | string | no | always |  |  |
| `[].url` | string | no | always |  |  |
| `[].user` | object | no | always |  | simple-user object, see bottom |

## GET /repos/{owner}/{repo}/pulls/comments (error responses)

Samples: `error-422-invalid-since.json`

| Key path | JSON type(s) | Nullable | Presence | Enum values seen | Only in samples |
|---|---|---|---|---|---|
| `documentation_url` | string | no | always |  |  |
| `message` | string | no | always |  |  |
| `status` | string | no | always | 422 |  |

## GET /repos/{owner}/{repo}/pulls/{n} (error responses)

Samples: `error-404-pull-not-found.json`

| Key path | JSON type(s) | Nullable | Presence | Enum values seen | Only in samples |
|---|---|---|---|---|---|
| `documentation_url` | string | no | always |  |  |
| `message` | string | no | always |  |  |
| `status` | string | no | always | 404 |  |

## GET /repos/{owner}/{repo}/pulls/{n}

Samples: `rest-pull-mergeable-dirty.json`, `rest-pull-mergeable-clean.json`, `rest-pull-mergeable-blocked.json`, `rest-pull-mergeable-unknown.json`

| Key path | JSON type(s) | Nullable | Presence | Enum values seen | Only in samples |
|---|---|---|---|---|---|
| `_links` | object | no | always |  |  |
| `_links.comments` | object | no | always |  |  |
| `_links.comments.href` | string | no | always |  |  |
| `_links.commits` | object | no | always |  |  |
| `_links.commits.href` | string | no | always |  |  |
| `_links.html` | object | no | always |  |  |
| `_links.html.href` | string | no | always |  |  |
| `_links.issue` | object | no | always |  |  |
| `_links.issue.href` | string | no | always |  |  |
| `_links.review_comment` | object | no | always |  |  |
| `_links.review_comment.href` | string | no | always |  |  |
| `_links.review_comments` | object | no | always |  |  |
| `_links.review_comments.href` | string | no | always |  |  |
| `_links.self` | object | no | always |  |  |
| `_links.self.href` | string | no | always |  |  |
| `_links.statuses` | object | no | always |  |  |
| `_links.statuses.href` | string | no | always |  |  |
| `active_lock_reason` | null | yes | always |  |  |
| `additions` | integer | no | always |  |  |
| `assignee` | null | yes | always |  |  |
| `assignees` | array | no | always |  | array of simple-user objects |
| `author_association` | string | no | always | MEMBER |  |
| `auto_merge` | null | yes | always |  |  |
| `base` | object | no | always |  |  |
| `base.label` | string | no | always |  |  |
| `base.ref` | string | no | always |  |  |
| `base.repo` | object | no | always |  | full repository object (children omitted) |
| `base.sha` | string | no | always |  |  |
| `base.user` | object | no | always |  | simple-user object, see bottom |
| `body` | string | no | always |  |  |
| `changed_files` | integer | no | always |  |  |
| `closed_at` | string | yes | always |  |  |
| `comments` | integer | no | always |  |  |
| `comments_url` | string | no | always |  |  |
| `commits` | integer | no | always |  |  |
| `commits_url` | string | no | always |  |  |
| `created_at` | string | no | always |  |  |
| `deletions` | integer | no | always |  |  |
| `diff_url` | string | no | always |  |  |
| `draft` | boolean | no | always |  |  |
| `head` | object | no | always |  |  |
| `head.label` | string | no | always |  |  |
| `head.ref` | string | no | always |  |  |
| `head.repo` | object | no | always |  | full repository object (children omitted) |
| `head.sha` | string | no | always |  |  |
| `head.user` | object | no | always |  | simple-user object, see bottom |
| `html_url` | string | no | always |  |  |
| `id` | integer | no | always |  |  |
| `issue_url` | string | no | always |  |  |
| `labels` | array | no | always |  |  |
| `locked` | boolean | no | always |  |  |
| `maintainer_can_modify` | boolean | no | always |  |  |
| `merge_commit_sha` | string | yes | always |  |  |
| `mergeable` | boolean | yes | always |  |  |
| `mergeable_state` | string | no | always | blocked, clean, dirty, unknown |  |
| `merged` | boolean | no | always |  |  |
| `merged_at` | string | yes | always |  |  |
| `merged_by` | object | yes | always |  | simple-user object, see bottom |
| `milestone` | null | yes | always |  |  |
| `node_id` | string | no | always |  |  |
| `number` | integer | no | always |  |  |
| `patch_url` | string | no | always |  |  |
| `rebaseable` | boolean | yes | always |  |  |
| `requested_reviewers` | array | no | always |  | array of simple-user objects |
| `requested_teams` | array | no | always |  |  |
| `review_comment_url` | string | no | always |  |  |
| `review_comments` | integer | no | always |  |  |
| `review_comments_url` | string | no | always |  |  |
| `state` | string | no | always | closed, open |  |
| `statuses_url` | string | no | always |  |  |
| `title` | string | no | always |  |  |
| `updated_at` | string | no | always |  |  |
| `url` | string | no | always |  |  |
| `user` | object | no | always |  | simple-user object, see bottom |

## GET /repos/{owner}/{repo}/pulls/{n}/comments

Samples: `transport-pagination-page1.json`, `transport-pagination-page2.json`, `rest-pull-review-comments-list.json`

| Key path | JSON type(s) | Nullable | Presence | Enum values seen | Only in samples |
|---|---|---|---|---|---|
| `[]._links` | object | no | always |  |  |
| `[]._links.html` | object | no | always |  |  |
| `[]._links.html.href` | string | no | always |  |  |
| `[]._links.pull_request` | object | no | always |  |  |
| `[]._links.pull_request.href` | string | no | always |  |  |
| `[]._links.self` | object | no | always |  |  |
| `[]._links.self.href` | string | no | always |  |  |
| `[].author_association` | string | no | always | MEMBER, NONE |  |
| `[].body` | string | no | always |  |  |
| `[].commit_id` | string | no | always |  |  |
| `[].copilot_code_review_severity` | string | yes | always | high, medium |  |
| `[].copilot_code_review_sources` | array | no | always |  |  |
| `[].created_at` | string | no | always |  |  |
| `[].diff_hunk` | string | no | always |  |  |
| `[].html_url` | string | no | always |  |  |
| `[].id` | integer | no | always |  |  |
| `[].in_reply_to_id` | integer | no | optional (6/14) |  |  |
| `[].is_copilot_code_review` | boolean | no | always |  |  |
| `[].line` | integer | yes | always |  |  |
| `[].node_id` | string | no | always |  |  |
| `[].original_commit_id` | string | no | always |  |  |
| `[].original_line` | integer | no | always |  |  |
| `[].original_position` | integer | no | always |  |  |
| `[].original_start_line` | integer | yes | always |  |  |
| `[].path` | string | no | always |  |  |
| `[].position` | integer | no | always |  |  |
| `[].pull_request_review_id` | integer | no | always |  |  |
| `[].pull_request_url` | string | no | always |  |  |
| `[].reactions` | object | no | always |  |  |
| `[].reactions.+1` | integer | no | always |  |  |
| `[].reactions.-1` | integer | no | always |  |  |
| `[].reactions.confused` | integer | no | always |  |  |
| `[].reactions.eyes` | integer | no | always |  |  |
| `[].reactions.heart` | integer | no | always |  |  |
| `[].reactions.hooray` | integer | no | always |  |  |
| `[].reactions.laugh` | integer | no | always |  |  |
| `[].reactions.rocket` | integer | no | always |  |  |
| `[].reactions.total_count` | integer | no | always |  |  |
| `[].reactions.url` | string | no | always |  |  |
| `[].side` | string | no | always | RIGHT |  |
| `[].start_line` | integer | yes | always |  |  |
| `[].start_side` | string | yes | always | RIGHT |  |
| `[].subject_type` | string | no | always | line |  |
| `[].updated_at` | string | no | always |  |  |
| `[].url` | string | no | always |  |  |
| `[].user` | object | no | always |  | simple-user object, see bottom |

## GET /repos/{owner}/{repo}/pulls/{n}/reviews

Samples: `rest-pull-reviews-empty.json`, `rest-pull-reviews-list.json`

| Key path | JSON type(s) | Nullable | Presence | Enum values seen | Only in samples |
|---|---|---|---|---|---|
| `[]._links` | object | no | always |  |  |
| `[]._links.html` | object | no | always |  |  |
| `[]._links.html.href` | string | no | always |  |  |
| `[]._links.pull_request` | object | no | always |  |  |
| `[]._links.pull_request.href` | string | no | always |  |  |
| `[].author_association` | string | no | always | MEMBER, NONE |  |
| `[].body` | string | no | always |  |  |
| `[].commit_id` | string | no | always |  |  |
| `[].copilot_code_review_effort` | string | yes | always | balanced |  |
| `[].html_url` | string | no | always |  |  |
| `[].id` | integer | no | always |  |  |
| `[].is_copilot_code_review` | boolean | no | always |  |  |
| `[].node_id` | string | no | always |  |  |
| `[].pull_request_url` | string | no | always |  |  |
| `[].state` | string | no | always | APPROVED, COMMENTED |  |
| `[].submitted_at` | string | no | always |  |  |
| `[].user` | object | no | always |  | simple-user object, see bottom |

## GET /repos/{owner}/{repo}/pulls/{n}/reviews/{review_id}

Samples: `rest-review-app-bot.json`, `rest-review-state-approved.json`, `rest-review-state-approved-empty-body.json`, `rest-review-state-changes-requested.json`, `rest-review-state-commented.json`, `rest-review-commented-empty-body-author.json`, `rest-review-copilot-bot.json`, `rest-review-state-dismissed-human.json`, `rest-review-github-actions-bot.json`, `rest-review-stale-commit.json`, `rest-review-state-dismissed-bot.json`

| Key path | JSON type(s) | Nullable | Presence | Enum values seen | Only in samples |
|---|---|---|---|---|---|
| `_links` | object | no | always |  |  |
| `_links.html` | object | no | always |  |  |
| `_links.html.href` | string | no | always |  |  |
| `_links.pull_request` | object | no | always |  |  |
| `_links.pull_request.href` | string | no | always |  |  |
| `author_association` | string | no | always | MEMBER, NONE |  |
| `body` | string | no | always |  |  |
| `commit_id` | string | no | always |  |  |
| `copilot_code_review_effort` | string | yes | always | balanced |  |
| `html_url` | string | no | always |  |  |
| `id` | integer | no | always |  |  |
| `is_copilot_code_review` | boolean | no | always |  |  |
| `node_id` | string | no | always |  |  |
| `pull_request_url` | string | no | always |  |  |
| `state` | string | no | always | APPROVED, CHANGES_REQUESTED, COMMENTED, DISMISSED |  |
| `submitted_at` | string | no | always |  |  |
| `user` | object | no | always |  | simple-user object, see bottom |

## GET /repos/{owner}/{repo}/pulls/{n}/reviews/{review_id}/comments

Samples: `rest-review-comments-for-review.json`, `rest-review-comments-for-review-empty.json`

| Key path | JSON type(s) | Nullable | Presence | Enum values seen | Only in samples |
|---|---|---|---|---|---|
| `[]._links` | object | no | always |  |  |
| `[]._links.html` | object | no | always |  |  |
| `[]._links.html.href` | string | no | always |  |  |
| `[]._links.pull_request` | object | no | always |  |  |
| `[]._links.pull_request.href` | string | no | always |  |  |
| `[]._links.self` | object | no | always |  |  |
| `[]._links.self.href` | string | no | always |  |  |
| `[].author_association` | string | no | always | MEMBER |  |
| `[].body` | string | no | always |  |  |
| `[].commit_id` | string | no | always |  |  |
| `[].copilot_code_review_severity` | null | yes | always |  |  |
| `[].copilot_code_review_sources` | array | no | always |  |  |
| `[].created_at` | string | no | always |  |  |
| `[].diff_hunk` | string | no | always |  |  |
| `[].html_url` | string | no | always |  |  |
| `[].id` | integer | no | always |  |  |
| `[].is_copilot_code_review` | boolean | no | always |  |  |
| `[].node_id` | string | no | always |  |  |
| `[].original_commit_id` | string | no | always |  |  |
| `[].original_position` | integer | no | always |  |  |
| `[].path` | string | no | always |  |  |
| `[].position` | integer | no | always |  |  |
| `[].pull_request_review_id` | integer | no | always |  |  |
| `[].pull_request_url` | string | no | always |  |  |
| `[].reactions` | object | no | always |  |  |
| `[].reactions.+1` | integer | no | always |  |  |
| `[].reactions.-1` | integer | no | always |  |  |
| `[].reactions.confused` | integer | no | always |  |  |
| `[].reactions.eyes` | integer | no | always |  |  |
| `[].reactions.heart` | integer | no | always |  |  |
| `[].reactions.hooray` | integer | no | always |  |  |
| `[].reactions.laugh` | integer | no | always |  |  |
| `[].reactions.rocket` | integer | no | always |  |  |
| `[].reactions.total_count` | integer | no | always |  |  |
| `[].reactions.url` | string | no | always |  |  |
| `[].updated_at` | string | no | always |  |  |
| `[].url` | string | no | always |  |  |
| `[].user` | object | no | always |  | simple-user object, see bottom |

## POST /graphql (query node(id) on PullRequestReviewThread)

Samples: `graphql-review-thread-bot-author.json`, `graphql-review-thread-multiline-range.json`, `graphql-review-thread-outdated.json`, `graphql-review-thread-resolved.json`, `graphql-review-thread-unresolved.json`

| Key path | JSON type(s) | Nullable | Presence | Enum values seen | Only in samples |
|---|---|---|---|---|---|
| `data` | object | no | always |  |  |
| `data.node` | object | no | always |  |  |
| `data.node.__typename` | string | no | always | PullRequestReviewThread |  |
| `data.node.comments` | object | no | always |  |  |
| `data.node.comments.nodes` | array | no | always |  |  |
| `data.node.comments.nodes[].author` | object | no | always |  |  |
| `data.node.comments.nodes[].author.__typename` | string | no | always | Bot, User |  |
| `data.node.comments.nodes[].author.login` | string | no | always |  |  |
| `data.node.comments.nodes[].authorAssociation` | string | no | always | MEMBER, NONE |  |
| `data.node.comments.nodes[].body` | string | no | always |  |  |
| `data.node.comments.nodes[].bodyText` | string | no | always |  |  |
| `data.node.comments.nodes[].commit` | object | no | always |  |  |
| `data.node.comments.nodes[].commit.oid` | string | no | always |  |  |
| `data.node.comments.nodes[].createdAt` | string | no | always |  |  |
| `data.node.comments.nodes[].databaseId` | integer | no | always |  |  |
| `data.node.comments.nodes[].diffHunk` | string | no | always |  |  |
| `data.node.comments.nodes[].id` | string | no | always |  |  |
| `data.node.comments.nodes[].isMinimized` | boolean | no | always |  |  |
| `data.node.comments.nodes[].lastEditedAt` | null | yes | always |  |  |
| `data.node.comments.nodes[].line` | integer | yes | always |  |  |
| `data.node.comments.nodes[].minimizedReason` | null | yes | always |  |  |
| `data.node.comments.nodes[].originalCommit` | object | no | always |  |  |
| `data.node.comments.nodes[].originalCommit.oid` | string | no | always |  |  |
| `data.node.comments.nodes[].originalLine` | integer | no | always |  |  |
| `data.node.comments.nodes[].originalStartLine` | integer | yes | always |  |  |
| `data.node.comments.nodes[].outdated` | boolean | no | always |  |  |
| `data.node.comments.nodes[].path` | string | no | always |  |  |
| `data.node.comments.nodes[].publishedAt` | string | no | always |  |  |
| `data.node.comments.nodes[].pullRequestReview` | object | no | always |  |  |
| `data.node.comments.nodes[].pullRequestReview.id` | string | no | always |  |  |
| `data.node.comments.nodes[].pullRequestReview.state` | string | no | always | COMMENTED |  |
| `data.node.comments.nodes[].reactionGroups` | array | no | always |  |  |
| `data.node.comments.nodes[].reactionGroups[].content` | string | no | always | CONFUSED, EYES, HEART, HOORAY, LAUGH, ROCKET, THUMBS_DOWN, THUMBS_UP |  |
| `data.node.comments.nodes[].reactionGroups[].reactors` | object | no | always |  |  |
| `data.node.comments.nodes[].reactionGroups[].reactors.totalCount` | integer | no | always |  |  |
| `data.node.comments.nodes[].replyTo` | object | yes | always |  |  |
| `data.node.comments.nodes[].replyTo.id` | string | no | always |  |  |
| `data.node.comments.nodes[].startLine` | integer | yes | always |  |  |
| `data.node.comments.nodes[].updatedAt` | string | no | always |  |  |
| `data.node.comments.nodes[].url` | string | no | always |  |  |
| `data.node.comments.pageInfo` | object | no | always |  |  |
| `data.node.comments.pageInfo.endCursor` | string | no | always |  |  |
| `data.node.comments.pageInfo.hasNextPage` | boolean | no | always |  |  |
| `data.node.comments.pageInfo.hasPreviousPage` | boolean | no | always |  |  |
| `data.node.comments.pageInfo.startCursor` | string | no | always |  |  |
| `data.node.comments.totalCount` | integer | no | always |  |  |
| `data.node.diffSide` | string | no | always | RIGHT |  |
| `data.node.id` | string | no | always |  |  |
| `data.node.isCollapsed` | boolean | no | always |  |  |
| `data.node.isOutdated` | boolean | no | always |  |  |
| `data.node.isResolved` | boolean | no | always |  |  |
| `data.node.line` | integer | yes | always |  |  |
| `data.node.originalLine` | integer | no | always |  |  |
| `data.node.originalStartLine` | integer | yes | always |  |  |
| `data.node.path` | string | no | always |  |  |
| `data.node.pullRequest` | object | no | always |  |  |
| `data.node.pullRequest.number` | integer | no | always |  |  |
| `data.node.resolvedBy` | object | yes | always |  |  |
| `data.node.resolvedBy.login` | string | no | always |  |  |
| `data.node.startDiffSide` | string | yes | always | RIGHT |  |
| `data.node.startLine` | integer | yes | always |  |  |
| `data.node.subjectType` | string | no | always | LINE |  |
| `data.node.viewerCanResolve` | boolean | no | always |  |  |

## POST /graphql (query pullRequest.reviewThreads

Samples: `graphql-pull-review-threads-and-reviews.json`

| Key path | JSON type(s) | Nullable | Presence | Enum values seen | Only in samples |
|---|---|---|---|---|---|
| `data` | object | no | always |  |  |
| `data.repository` | object | no | always |  |  |
| `data.repository.pullRequest` | object | no | always |  |  |
| `data.repository.pullRequest.author` | object | no | always |  |  |
| `data.repository.pullRequest.author.__typename` | string | no | always | User |  |
| `data.repository.pullRequest.author.login` | string | no | always |  |  |
| `data.repository.pullRequest.id` | string | no | always |  |  |
| `data.repository.pullRequest.number` | integer | no | always |  |  |
| `data.repository.pullRequest.reviewThreads` | object | no | always |  |  |
| `data.repository.pullRequest.reviewThreads.nodes` | array | no | always |  |  |
| `data.repository.pullRequest.reviewThreads.nodes[].comments` | object | no | always |  |  |
| `data.repository.pullRequest.reviewThreads.nodes[].comments.nodes` | array | no | always |  |  |
| `data.repository.pullRequest.reviewThreads.nodes[].comments.nodes[].author` | object | no | always |  |  |
| `data.repository.pullRequest.reviewThreads.nodes[].comments.nodes[].author.__typename` | string | no | always | Bot, User |  |
| `data.repository.pullRequest.reviewThreads.nodes[].comments.nodes[].author.login` | string | no | always |  |  |
| `data.repository.pullRequest.reviewThreads.nodes[].comments.nodes[].authorAssociation` | string | no | always | MEMBER, NONE |  |
| `data.repository.pullRequest.reviewThreads.nodes[].comments.nodes[].body` | string | no | always |  |  |
| `data.repository.pullRequest.reviewThreads.nodes[].comments.nodes[].createdAt` | string | no | always |  |  |
| `data.repository.pullRequest.reviewThreads.nodes[].comments.nodes[].databaseId` | integer | no | always |  |  |
| `data.repository.pullRequest.reviewThreads.nodes[].comments.nodes[].diffHunk` | string | no | always |  |  |
| `data.repository.pullRequest.reviewThreads.nodes[].comments.nodes[].id` | string | no | always |  |  |
| `data.repository.pullRequest.reviewThreads.nodes[].comments.nodes[].isMinimized` | boolean | no | always |  |  |
| `data.repository.pullRequest.reviewThreads.nodes[].comments.nodes[].lastEditedAt` | null | yes | always |  |  |
| `data.repository.pullRequest.reviewThreads.nodes[].comments.nodes[].line` | integer | yes | always |  |  |
| `data.repository.pullRequest.reviewThreads.nodes[].comments.nodes[].minimizedReason` | null | yes | always |  |  |
| `data.repository.pullRequest.reviewThreads.nodes[].comments.nodes[].originalLine` | integer | no | always |  |  |
| `data.repository.pullRequest.reviewThreads.nodes[].comments.nodes[].outdated` | boolean | no | always |  |  |
| `data.repository.pullRequest.reviewThreads.nodes[].comments.nodes[].path` | string | no | always |  |  |
| `data.repository.pullRequest.reviewThreads.nodes[].comments.nodes[].pullRequestReview` | object | no | always |  |  |
| `data.repository.pullRequest.reviewThreads.nodes[].comments.nodes[].pullRequestReview.id` | string | no | always |  |  |
| `data.repository.pullRequest.reviewThreads.nodes[].comments.nodes[].pullRequestReview.state` | string | no | always | APPROVED, COMMENTED |  |
| `data.repository.pullRequest.reviewThreads.nodes[].comments.nodes[].reactionGroups` | array | no | always |  |  |
| `data.repository.pullRequest.reviewThreads.nodes[].comments.nodes[].reactionGroups[].content` | string | no | always | CONFUSED, EYES, HEART, HOORAY, LAUGH, ROCKET, THUMBS_DOWN, THUMBS_UP |  |
| `data.repository.pullRequest.reviewThreads.nodes[].comments.nodes[].reactionGroups[].reactors` | object | no | always |  |  |
| `data.repository.pullRequest.reviewThreads.nodes[].comments.nodes[].reactionGroups[].reactors.totalCount` | integer | no | always |  |  |
| `data.repository.pullRequest.reviewThreads.nodes[].comments.nodes[].replyTo` | object | yes | always |  |  |
| `data.repository.pullRequest.reviewThreads.nodes[].comments.nodes[].replyTo.id` | string | no | always |  |  |
| `data.repository.pullRequest.reviewThreads.nodes[].comments.nodes[].updatedAt` | string | no | always |  |  |
| `data.repository.pullRequest.reviewThreads.nodes[].comments.nodes[].url` | string | no | always |  |  |
| `data.repository.pullRequest.reviewThreads.nodes[].comments.pageInfo` | object | no | always |  |  |
| `data.repository.pullRequest.reviewThreads.nodes[].comments.pageInfo.endCursor` | string | no | always |  |  |
| `data.repository.pullRequest.reviewThreads.nodes[].comments.pageInfo.hasNextPage` | boolean | no | always |  |  |
| `data.repository.pullRequest.reviewThreads.nodes[].comments.totalCount` | integer | no | always |  |  |
| `data.repository.pullRequest.reviewThreads.nodes[].diffSide` | string | no | always | RIGHT |  |
| `data.repository.pullRequest.reviewThreads.nodes[].id` | string | no | always |  |  |
| `data.repository.pullRequest.reviewThreads.nodes[].isCollapsed` | boolean | no | always |  |  |
| `data.repository.pullRequest.reviewThreads.nodes[].isOutdated` | boolean | no | always |  |  |
| `data.repository.pullRequest.reviewThreads.nodes[].isResolved` | boolean | no | always |  |  |
| `data.repository.pullRequest.reviewThreads.nodes[].line` | integer | yes | always |  |  |
| `data.repository.pullRequest.reviewThreads.nodes[].originalLine` | integer | no | always |  |  |
| `data.repository.pullRequest.reviewThreads.nodes[].originalStartLine` | integer | yes | always |  |  |
| `data.repository.pullRequest.reviewThreads.nodes[].path` | string | no | always |  |  |
| `data.repository.pullRequest.reviewThreads.nodes[].resolvedBy` | object | yes | always |  |  |
| `data.repository.pullRequest.reviewThreads.nodes[].resolvedBy.login` | string | no | always |  |  |
| `data.repository.pullRequest.reviewThreads.nodes[].startDiffSide` | string | yes | always | RIGHT |  |
| `data.repository.pullRequest.reviewThreads.nodes[].startLine` | integer | yes | always |  |  |
| `data.repository.pullRequest.reviewThreads.nodes[].subjectType` | string | no | always | LINE |  |
| `data.repository.pullRequest.reviewThreads.pageInfo` | object | no | always |  |  |
| `data.repository.pullRequest.reviewThreads.pageInfo.endCursor` | string | no | always |  |  |
| `data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage` | boolean | no | always |  |  |
| `data.repository.pullRequest.reviewThreads.totalCount` | integer | no | always |  |  |
| `data.repository.pullRequest.reviews` | object | no | always |  |  |
| `data.repository.pullRequest.reviews.nodes` | array | no | always |  |  |
| `data.repository.pullRequest.reviews.nodes[].author` | object | no | always |  |  |
| `data.repository.pullRequest.reviews.nodes[].author.__typename` | string | no | always | Bot, User |  |
| `data.repository.pullRequest.reviews.nodes[].author.login` | string | no | always |  |  |
| `data.repository.pullRequest.reviews.nodes[].authorAssociation` | string | no | always | MEMBER, NONE |  |
| `data.repository.pullRequest.reviews.nodes[].body` | string | no | always |  |  |
| `data.repository.pullRequest.reviews.nodes[].comments` | object | no | always |  |  |
| `data.repository.pullRequest.reviews.nodes[].comments.totalCount` | integer | no | always |  |  |
| `data.repository.pullRequest.reviews.nodes[].commit` | object | no | always |  |  |
| `data.repository.pullRequest.reviews.nodes[].commit.oid` | string | no | always |  |  |
| `data.repository.pullRequest.reviews.nodes[].createdAt` | string | no | always |  |  |
| `data.repository.pullRequest.reviews.nodes[].databaseId` | integer | no | always |  |  |
| `data.repository.pullRequest.reviews.nodes[].id` | string | no | always |  |  |
| `data.repository.pullRequest.reviews.nodes[].isMinimized` | boolean | no | always |  |  |
| `data.repository.pullRequest.reviews.nodes[].state` | string | no | always | APPROVED, COMMENTED |  |
| `data.repository.pullRequest.reviews.nodes[].submittedAt` | string | no | always |  |  |
| `data.repository.pullRequest.reviews.nodes[].updatedAt` | string | no | always |  |  |
| `data.repository.pullRequest.reviews.nodes[].url` | string | no | always |  |  |
| `data.repository.pullRequest.reviews.pageInfo` | object | no | always |  |  |
| `data.repository.pullRequest.reviews.pageInfo.endCursor` | string | no | always |  |  |
| `data.repository.pullRequest.reviews.pageInfo.hasNextPage` | boolean | no | always |  |  |
| `data.repository.pullRequest.reviews.totalCount` | integer | no | always |  |  |
| `data.repository.pullRequest.state` | string | no | always | MERGED |  |

## POST /graphql (query)

Samples: `graphql-error-pull-not-found.json`

| Key path | JSON type(s) | Nullable | Presence | Enum values seen | Only in samples |
|---|---|---|---|---|---|
| `data` | object | no | always |  |  |
| `data.repository` | object | no | always |  |  |
| `data.repository.pullRequest` | null | yes | always |  |  |
| `errors` | array | no | always |  |  |
| `errors[].locations` | array | no | always |  |  |
| `errors[].locations[].column` | integer | no | always |  |  |
| `errors[].locations[].line` | integer | no | always |  |  |
| `errors[].message` | string | no | always |  |  |
| `errors[].path` | array | no | always |  |  |
| `errors[].type` | string | no | always | NOT_FOUND |  |

## Simple user object (REST `user`, `owner`, `merged_by`, `assignee`, `assignees[]`, `requested_reviewers[]`)

Built from 120 user objects across all REST samples.

| Key | JSON type(s) | Presence | Enum values seen |
|---|---|---|---|
| `login` | string | always |  |
| `id` | integer | always |  |
| `node_id` | string | always |  |
| `avatar_url` | string | always |  |
| `gravatar_id` | string | always |  |
| `url` | string | always |  |
| `html_url` | string | always |  |
| `followers_url` | string | always |  |
| `following_url` | string | always |  |
| `gists_url` | string | always |  |
| `starred_url` | string | always |  |
| `subscriptions_url` | string | always |  |
| `organizations_url` | string | always |  |
| `repos_url` | string | always |  |
| `events_url` | string | always |  |
| `received_events_url` | string | always |  |
| `type` | string | always | Bot, Organization, User |
| `user_view_type` | string | always | public |
| `site_admin` | boolean | always |  |

## Cross-endpoint call-outs

- `body_html` and `body_text` appear only with `.html+json`, `.text+json` or `.full+json`. Issue comments drop `body` under `.html+json`/`.text+json`; review comments keep it.
- `in_reply_to_id` exists only on reply review comments.
- `performed_via_github_app` is always present on issue comments: an object for App/Actions comments, null for users.
- `copilot_code_review_sources` is present on every review comment (usually `[]`); `copilot_code_review_effort` appears on review objects.
- GraphQL `startDiffSide`, `startLine`, `originalStartLine` are null for single-line threads; `resolvedBy` is null for unresolved threads; `line` is null for outdated threads.
