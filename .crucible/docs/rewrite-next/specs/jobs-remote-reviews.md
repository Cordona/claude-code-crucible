# Jobs: remote reviews (foreign-review, external-review)

Two reviewer kinds still start on the frozen `job.dispatched`: `foreign-review` (we review someone else's PR/MR) and `external-review` (we judge an outside review of our PR/MR). Their inputs are not events yet. This draft makes them facts and moves both kinds to `job.defined`.

"Change" means a GitHub pull request or a GitLab merge request; "remote" the host it lives on. Trackers stay issues only.

## 1. The new skill `remotes/`

`new-rewrite/domains/software-development/core/main-thread/remotes/`, beside `trackers/`. Read-only on the remote. In the human's repo it adds only the change's commits as git objects: `git fetch --no-write-fetch-head`, so no ref, no `FETCH_HEAD`, no branch, no checkout change.

```
remotes/
  SKILL.md
  events/
    remote-change.fetched.jq
    remote-review.fetched.jq
  scripts/
    main/
      change-fetch.sh     # writes remote-change.fetched
      review-fetch.sh     # writes remote-review.fetched
    lib/
      remote-host.sh      # the link: github or gitlab, owner/repo or project path, number
      github.jq           # GitHub's replies -> the common shape
      gitlab.jq           # GitLab's replies -> the common shape
```

The safe-link check moves out of `trackers/tracker-read.sh` into dev-base, as `scripts/internal/safe-link.sh` beside `run-timed.sh`; both trackers and remotes use it. Neither needs a gate: nothing on the remote changes, and nothing in the human's work tree.

### `change-fetch.sh --effort F --repo R --url URL`

1. The link: `github.com/O/R/pull/N` or a GitLab `…/-/merge_requests/N` (dev-base's `safe-link.sh`).
2. `change-read.sh`: the change from the host. Title, description, author, state, base branch, head sha, and the base the host recorded: GitLab's `diff_refs.base_sha`, GitHub's `base.sha`.
3. `change-commits.sh`: the commits into `R`, as objects only. `git fetch --no-write-fetch-head --refmap=` writes no ref and no `FETCH_HEAD`.
   - It fetches the change's ref (`refs/pull/N/head`, `refs/merge-requests/N/head`), or the head by sha once the host has dropped the ref (GitLab drops a merged request's), plus the recorded base by sha.
   - `<remote>` is R's remote whose URL names the change's host and project; none matching refuses.
   - The head the fetch brings must be the host's head.
4. `base` = `git merge-base <recorded base> <head>`. On GitLab this is the recorded base itself; on GitHub, whose `base.sha` is the base branch's tip as last recorded, it is the fork point.
5. Writes the description file, then the event.

### `review-fetch.sh --effort F --change SEQ [--bot NAME]...`

1. The change from its `remote-change.fetched`.
2. `review-read.sh`: every review thread, resolved ones flagged, with its comments, from the host (section 3), in the common shape.
3. Writes the threads file, then the event.

## 2. The events

### `remote-change.fetched`

```json
{
  "host": "gitlab",
  "url": "https://gitlab.example.com/group/app/-/merge_requests/42",
  "repo": "/Users/someone/src/app",
  "number": 42,
  "base": "<full sha: merge base>",
  "head": "<full sha: the change's head>",
  "author": "jdoe",
  "report": {
    "path": "reports/remote-change/17.json",
    "sha256": "<64 hex>"
  }
}
```

The pinned file holds what the change's author wrote, untrusted text, so it stays out of the event:

```json
{
  "title": "Add the shout flag",
  "description": "…",
  "base_branch": "main",
  "state": "opened"
}
```

### `remote-review.fetched`

```json
{
  "change": 17,
  "head": "<full sha: the change's head when the threads were read>",
  "threads": 5,
  "bots": ["review-bot"],
  "report": {
    "path": "reports/remote-review/23.json",
    "sha256": "<64 hex>"
  }
}
```

The pinned threads file: one shape from both hosts' real replies (`spikes/remotes/gitlab-findings.md`, `github-findings.md`), aligned with the Plugins workers and Fable (`spikes/remotes/worker-answers.md`). `review-fetch.sh` writes what the host says and keeps no memory.

```json
{
  "threads": [
    {
      "id": "<the host's thread, review or comment id>",
      "resolved": false,
      "commit": "<full sha the opening comment was made on>",
      "path": "src/app/Service.php",
      "new_line": 170,
      "comments": [
        {"id": "13552", "source": "human", "role": "reviewer", "updated": "2026-11-27T10:02:00Z", "body": "…"},
        {"id": "13573", "source": "human", "role": "author", "updated": "2026-11-27T11:15:00Z", "body": "…"}
      ]
    }
  ]
}
```

| Field | Its reader |
|---|---|
| `id` | the report rules (every judged thread answered), the stamps, the comparison |
| `resolved` | the comparison (a flip makes a thread changed); the reviewer |
| `commit`: as the host gives it (a line comment on either host, a GitHub review); on GitLab, for a note with no position, the head of the latest version before it (one `versions` read per change: GitLab's main review form is one such note citing `path:line` in its text, and after the fix push those lines no longer match the head); absent only where neither exists (a GitHub conversation comment) | the reviewer: what the point was read against, compared with the event's `head` |
| `path`, `new_line` / `old_line`: only on a comment on a line, as on `commit` | the reviewer |
| `comments[]`, oldest first: `id`, `source`, `role`, `updated` (GitLab also moves it when the thread is resolved: it sets every note's `updated_at` to `resolved_at`), `body` (untrusted); `role` `author` is the change's author (the fixer side), else `reviewer` | the reviewer; `id` and `updated` also the comparison; `id` the later reply; the first comment's `source` and `role` are the thread's: the stamps take its `source`, and the facts judge only threads a `reviewer` opened |

Left out: system notes, empty bodies (GitHub's implicit and empty reviews), `DISMISSED` reviews. Resolved threads stay, flagged.

**New, changed, seen.** The reviewer's facts script compares this file with the one the last `external-review.submitted` of the same change before this job's `job.defined` read, both pinned. Bounded by the job, the answer is the same at the start, at the report check and for anyone auditing later. A thread is `new` (its id unseen), `changed` (a comment added, a comment's `updated` moved, or `resolved` flipped) or `seen`. Only `new` and `changed` reviewer threads must be judged; the rest go to the reviewer as context. A fetch that no review handed in, or a review that died, changes nothing, so no point is skipped. The facts script finds that earlier file in the log itself, so main names nothing and resolve needs no new word.

### Why pinned like a report

`events-view.sh` already joins every event whose body holds `report {path, sha256}` to that file, refusing the whole view when one changed. So both files get the same tamper check, and an agent's facts script reads them through `refs` without any new code in `jobs/track`. Both paths match `reports/<kind>/<seq>.json`. A fetched file can't pass for a hand-in: its body names no job. `events-view.sh`'s help says once that it joins any pinned file, not only hand-ins.

### The rules (`*.fetched.jq`)

- written only by its script;
- `remote-change`: host `github` or `gitlab`; url the accepted form; repo absolute; number a whole number; base and head full shas;
- `remote-review`: `change` is the seq of a `remote-change.fetched`; `head` a full sha; `threads` a count;
- the `report` pin in shape: path `reports/remote-change/<seq>.json` (or `remote-review`), the event's own seq.

## 3. GitHub and GitLab, into one shape

Where each field comes from on each host, from the real replies: `spikes/remotes/github-findings.md` and `spikes/remotes/gitlab-findings.md`. The decisions:

- GitHub: line threads and review summaries from GraphQL, conversation comments from REST; empty and `DISMISSED` reviews left out; a line is `originalLine`, on the side it's on, which matches `commit`.
- GitLab: discussions and versions; system notes left out.
- Resolved threads are kept on both, with `resolved`, and `false` where the host can't resolve.
- **The host can't always tell a bot.** A read-only check on 2026-11-27, on the owner's `glab` login, of an MR the owner said to use: the AI reviewer posts as an ordinary user (`users/:id` says `bot: false`), and note authors carry no bot field at all. So `review-fetch.sh` takes `--bot NAME`, repeatable, optional: the accounts the human names as AI. Without it every GitLab author is human; GitHub's `Bot` still counts. Main asks only when the human mentions an AI reviewer or the threads make it obvious. A later fetch of the same change takes the previous fetch's `bots` unless `--bot` is given. The event records the names in `bots: [...]`, so the fact is in the log.

## 4. The kinds

### `kinds/foreign-review.json`

```json
{
  "agent": "code-reviewer",
  "part": "review",
  "input_refs": {
    "context": {"event": "context.cut"},
    "change": {"event": "remote-change.fetched", "required": true, "named": true}
  },
  "tree": ["cut"],
  "range": "change",
  "write_scope": "report",
  "one_standard": true
}
```

Main proposes only `{kind: "foreign-review", plugins, input_refs: {change: 17}}`: no `work`. Resolve fills the tree, `{cut: {repo: <the change's repo>, from: "ref:<the change's head sha>"}}` (the cut takes a full sha after `ref:`), and the range from the change. Main types no sha.

### `kinds/external-review.json`

```json
{
  "agent": "code-reviewer",
  "part": "review",
  "input_refs": {
    "context": {"event": "context.cut", "required": true},
    "spec": {"event": "spec.approved"},
    "grills": {"event": "grill.ended", "list": true},
    "review": {"event": "remote-review.fetched", "required": true, "named": true}
  },
  "tree": ["use"],
  "range": "tree",
  "write_scope": "report"
}
```

The kind keeps its name, `external-review`: the reviewer's submission, report rules and stamps already use it.

### One kind-file word changes: `range`

`range` becomes where the range comes from, not just whether there is one. A new value, because resolve must check a new fact:

- `"tree"` (today's `true`): the used tree's base up to its head now. `review.json` changes to this.
- `"change"`: `{base, head}` of the change the job's `change` ref names; resolve also fills the cut from it, so the tree and the range are the same commits by construction, and refuses a `work` main gave.

`job.defined` lets a range sit on a cut tree too. Today it allows a range only on a used tree. The range then comes from the change, not from the tree.

## 5. The reviewer's side

- `reviewer-facts.sh` and `reviewer-stamp-facts.sh` read the threads from `refs.review`'s pinned file through `events-view.sh`, as `tester-facts.sh` reads `refs.plan`, in place of the job's `threads` path.
- `foreign-review`'s prompt gets the change's title and description by ref, as untrusted data.
- `external-review`: the reviewer's facts follow the `review` ref to its change and read the change's pinned description. No new ref.
- Prose: `code-reviewer.md` already has both sections; only the line "their line numbers are from the commit they reviewed" stays true (the `commit` field now says which).
- The two kinds leave the frozen `job.dispatched`; it then serves only build-fix and test-fix.
- Not in this step: posting the reviewer's findings or replies back to the remote. That is a write and gets its own gated piece later.

## 6. Validation, in order

1. **The read scripts, run.** Each fetch is split into a read step, which prints JSON, and the step that pins and writes the event. The read steps are run first.
   - **GitLab:** live and read-only, on the owner's `glab` login, on the MRs the owner named through the Plugins Observer, against sandbox clones. Check whether each point of a many-point AI note gets its own item when the reviewer judges it later.
   - **GitHub:** on `gh` stubs that replay the owner's scrubbed samples (commit `6352454`): line threads, review summaries, conversation comments, bots, outdated, resolved, multi-line, empty and dismissed reviews, paging headers, a 404, and GraphQL `NOT_FOUND`.
   - **Not proven by stubs:** that the query the script sends brings that reply back; real paging; the link from a line thread to its review (the samples collapse GraphQL ids); GitHub's base (`merge-base(base.sha, head)`). This is reported as not proven. One public read-only call would close it; that is the owner's call.
2. **Gate.** The owner sees the two events' bodies and the threads file as real output, and approves them before the event rules are written.
3. **The events:** the rules, the pinning and the event writes; then the kinds and the reviewer's facts.
4. **Evidence runs (`evidence/remotes/run.sh`).** The GitHub fixtures come from the scrubbed samples. The GitLab ones are written by hand from the shape seen: nothing captured from a private project goes into the repo.
5. **The chain, live (`jobs-live/live.sh`),** for foreign-review and external-review.

`remotes/SKILL.md` goes to Fable before a session uses it.
