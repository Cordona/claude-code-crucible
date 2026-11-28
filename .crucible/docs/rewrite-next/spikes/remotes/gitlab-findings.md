# GitLab, as it really answers (read-only, 2026-11-27)

Five real MRs our workers opened, on a self-hosted GitLab, read on the owner's `glab` login with the owner's yes: `merge_requests/N`, `.../discussions` (paginated) and `.../versions`. The raw replies stay in the session scratchpad. Here only their structure appears: no host, no names, no comment text.

## What came back

| MR | Comments (not system) | Shape |
|---|---|---|
| A | AI review, worker reply | 2 individual notes |
| B | AI review, worker reply | 2 individual notes |
| C | AI review, worker reply | 2 individual notes |
| D | AI review, worker reply, human reviewer, worker reply | 4 individual notes |
| E | human review, worker reply | 1 resolvable `DiscussionNote` (unresolved, no position), 1 individual note |

- **No line comments.** No `DiffNote` anywhere, and `position` is null on every note. Reviewers cite `path:line` inside the body instead (E's review: 4 such).
- **No reply threads.** Every reply is a separate top-level note by the MR's author, posted after the push that fixed it. Nothing links it to the note it answers: no `#note_N`, no quote. Order and time are the only link.
- **One note, many points.** An AI review is a single note of 5–9 KB holding many findings. A human review is a single note too, 0.3–3.3 KB.
- **Who's a bot.** The AI reviewer is an ordinary user (`users/:id` `bot: false`). Note authors carry no bot field.
- **The fixer.** The worker posts under the MR author's account, so the change's author is the fixer side.
- **System notes** are most of the rest: "added N commits", "requested review", "mentioned in". The "added N commits" note links to a diff version.
- **Which commit a comment was on.** `versions` lists `{id, head_commit_sha, created_at}` for every push. A note's commit is the head of the latest version created before it. On B: the AI review (11:35) sits on the version from 11:30, and the worker's reply (next day) on the version right after the fix push.
- `diff_refs {base_sha, head_sha, start_sha}` on the MR: `base_sha` is the merge base.

## What this changes in the draft

1. **The fixer's replies.** The draft dropped "threads the change's author opened". That drops every fixer reply here. Instead, keep them, marked with their opener's `role`; only threads a reviewer opened are judged.
2. **`commit` belongs on every thread**, from `versions`, not only on line comments. It is the commit the reviewer must read the point against.
3. **`path` and `line`** stay optional and are empty here. They come back when a `DiffNote` does (still unseen on GitLab).
4. **Resolution says little on GitLab:** individual notes can't be resolved. A second fetch brings the same AI review back, so the reviewer would judge it twice. **Open:** a later fetch takes only notes newer than the previous fetch of the same change, or the facts leave out threads an earlier external-review on that change already judged.
5. **Still unseen:** more than 100 notes and paging (a public GitLab.com MR), a comment on a removed line.

## Second read: six more MRs (line comments, resolved, long threads)

Each one read in the same three calls. Five are merged; one is open (read only, with extra care).

- **Real threads exist** where humans review. A `DiscussionNote` discussion is a thread on the change as a whole. A `DiffNote` discussion is a thread on a line. Replies sit inside the discussion, usually from the MR's author (the fixer).
- **A `DiffNote`'s `position`:** `position_type: "text"`, `new_path`, `new_line`, `old_line` (null on every one seen: all on added or changed lines), `head_sha` (the commit the comment was made on: no versions lookup needed), and `line_range` on most (a span of lines).
- **Resolution:** `resolvable: true` on every discussion note, `resolved` on each note. Seen resolved by the MR's author (the fixer, most of them) and by someone else (two). Individual notes are never resolvable.
- **Author-opened threads:** several, some with only the author's notes (one of 11 notes, all the author's: a running log of the fix). They are not points to judge, but they hold the fixer's account of what was done.
- **The AI reviewer:** still one individual note per review, 4–10 KB, never a line comment.
- **Tiny notes:** a resolved reviewer note of 2–5 characters (an acknowledgement).

## The threads shape, from what both reads show

```json
{
  "threads": [
    {
      "id": "<discussion id>",
      "source": "human",
      "role": "reviewer",
      "commit": "<full sha>",
      "path": "src/app/Service.php",
      "line": 170,
      "comments": [
        {"source": "human", "role": "reviewer", "body": "…"},
        {"source": "human", "role": "author", "body": "…"}
      ]
    }
  ]
}
```

| Field | GitLab, as seen | Its reader |
|---|---|---|
| `id` | the discussion id | report rules, stamps |
| `source` | the opener: `bot` only by `--bot NAME` | stamps |
| `role` | the opener: `author` when it's the MR's author, else `reviewer` | the facts: only `reviewer` threads are judged; `author` threads are context |
| `commit` | a `DiffNote`'s `position.head_sha`; otherwise the head of the latest version before the opening note | the reviewer: what the point was read against |
| `path`, `line` | a `DiffNote`'s `new_path`, `new_line` (or `old_line`); absent otherwise | the reviewer |
| `comments[]` | the discussion's notes, oldest first, no system notes | the reviewer |

Left out: resolved discussions, system notes, empty bodies.

## Third read: the scripts' runs (2026-11-27)

`change-read.sh`, `review-read.sh` and `change-commits.sh` were run on 6 MRs for review threads and 5 for commits, against a sandbox clone. Found and fixed in the runs:

- **A merged MR's `refs/merge-requests/N/head` is gone:** GitLab drops it. The fetch falls back to the head by sha.
- **The base branch's tip is the wrong base once a change is merged:** the merge base would be the head itself. The base the host recorded is used instead: GitLab's `diff_refs.base_sha`, GitHub's `base.sha`. It is fetched by sha.
- **Fetching a branch updates its remote-tracking ref opportunistically,** even with `--no-write-fetch-head`. `--refmap=` stops it. Now no ref is added and there is no `FETCH_HEAD`.
- **The owner's checkout's `origin` names another host than the MR's project.** The script refuses (no remote names the change's project) instead of fetching from the wrong place.
- **SSH to the host times out; HTTPS works** with git's own credentials.

**Results:**
- On all 5 MRs, the range's changed-file count equals GitLab's own `changes_count`: 24, 16, 2, 53 and 35.
- The merge base equals `diff_refs.base_sha`.
