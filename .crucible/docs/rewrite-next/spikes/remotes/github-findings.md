# GitHub, as it really answers (2026-11-27)

Source: the owner's scrubbed, shape-only samples of real GitHub replies: keys, nesting, types and enums real, values synthetic. They are in commit `6352454` (`gh-review-shapes/`, its `index.md` and `fields.md`) on `origin/chore/framework-improvements`. Read with `git archive`, not checked out.

## What a review is made of

| Piece | Where | Threaded | Resolvable | Its commit |
|---|---|---|---|---|
| Line threads | GraphQL `pullRequest.reviewThreads`: `id` (`PRRT_`), `isResolved`, `isOutdated`, `path`, `line`, `originalLine`, `startLine`, `diffSide` (`RIGHT`, and `LEFT` unseen), `subjectType`, `comments {databaseId, author {login, __typename}, body, createdAt, updatedAt, replyTo, pullRequestReview {id, state}}` | yes: replies are its later comments | yes | the review its first comment belongs to: `reviews[].commit.oid`; REST has it directly as `original_commit_id` |
| Review summaries | GraphQL `pullRequest.reviews`: `id` (`PRR_`), `databaseId`, `author`, `body`, `state` (`APPROVED`, `CHANGES_REQUESTED`, `COMMENTED`, `DISMISSED`), `commit.oid`, `updatedAt` | no: a reply is a conversation comment | no | `commit.oid` |
| Conversation comments | REST `issues/{n}/comments`: `id`, `user {login, type}`, `body`, `created_at`, `updated_at`, `performed_via_github_app` | no | no | none given |

- **Bot or human is knowable:** GraphQL `author.__typename == "Bot"`, REST `user.type == "Bot"`. Logins differ by endpoint: Copilot is `Copilot` on review comments, `copilot-pull-request-reviewer[bot]` on reviews, and `copilot-pull-request-reviewer` in GraphQL. So `--bot NAME` isn't needed on GitHub.
- **Empty review bodies are common.** An inline reply creates an implicit `COMMENTED` review with body `""`, and approvals are often empty. Only reviews with a body are points.
- **`DISMISSED` reviews** carry a withdrawn point.
- **Outdated:** `isOutdated: true`, `line: null`, `originalLine` kept: the line as it was on the commit the comment was made on.
- **A multi-line comment:** `startLine` < `line`.
- **Edited:** `updatedAt` after `createdAt`.
- **Paging:** GraphQL `pageInfo` and `totalCount` on threads, on comments in a thread, and on reviews. REST: the `Link` header (`gh api --paginate`).
- **Not seen in the samples:** a `LEFT` side, a file-level comment (`subjectType: FILE`), a minimized comment, a deleted user (`ghost`), a reply by someone other than the PR's author.

## Into the common threads shape

| Field | GitHub | GitLab |
|---|---|---|
| `id` | the thread id; the review id; the comment id | the discussion id |
| `commit` | a line thread: its first comment's review's `commit.oid`; a review: `commit.oid`; a conversation comment: none | a `DiffNote`: `position.head_sha`; other notes: none (not guessed from versions) |
| `path` | the thread's `path` | `position.new_path` |
| `new_line` / `old_line` | `originalLine`, on `RIGHT` / `LEFT` | `position.new_line` / `position.old_line` |
| `resolved` | `isResolved`; reviews and comments are not resolvable, so `false` | `resolved`; individual notes `false` |
| `comments[].id` | `databaseId`, or the REST `id` | the note's `id` |
| `comments[].updated` | `updatedAt`, `updated_at` | `updated_at` |
| `comments[].source` | `__typename` or `type` is `Bot` | `--bot NAME` |
| `comments[].role` | `author` for the PR's author, else `reviewer` | the same, by the MR's author |
| `comments[].body` | `body` | `body` |

Left out on both hosts:
- system notes;
- empty bodies, which drops the implicit and empty reviews;
- `DISMISSED` reviews.
