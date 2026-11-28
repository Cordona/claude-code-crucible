# The Plugins workers on the review fetch (2026-11-27)

The question: does the threads shape `{id, source, role, commit, path?, line?, comments [{source, role, body}]}` give a worker what it uses to answer a review, and what counts as "new since last look"?

## How they work today (the Plugins Observer)

- No fetch tool: `glab api` on `.../notes` or `.../discussions`, filtered with jq, system notes skipped.
- They ask the AI reviewer by adding a label (`ai-review-please`); the bot changes it to `ai-reviewed` once it has posted.
- AI and human are told apart by username only; GitLab's `bot` flag is false for the bot. The workers post under the owner's account.
- A reply goes to the bot's one note as one note, taking its points in order: fixed (with the commit), not a defect (with the reason), or deferred. To a human's resolvable thread, the reply goes into the thread, left unresolved for the reviewer.
- Workers never resolve threads. The reviewer or the owner does.
- Nothing is saved between looks: re-list newest first and compare with the last note handled by hand. Missed reviews surface only when the observer polls.

## Plugins Dev Gamma (harbinger, a human's resolvable thread)

1. Also needed:
   - the diff position (old and new line, `line_range`, the base, head and start shas), to tell whether a comment is outdated against the head;
   - a thread's resolvable and resolved flags;
   - each note's id, `created_at` and `updated_at`;
   - the MR's description;
   - which notes are already our replies;
   - code suggestions, worth parsing.
2. "Newer than the last fetch" is not enough, because these matter:
   - a reviewer replying again in a thread already answered;
   - a thread reopened;
   - an edited note.

   Count as new any note whose `updated_at` is after the last fetch, and any thread whose resolved state changed, and return the whole thread for context. Don't drop resolved threads entirely: one resolved since the last look is worth knowing.

## Plugins Dev Alpha (core-api, the AI reviewer)

1. Also needed:
   - each note's id plus the discussion id (what a reply takes);
   - `created_at` and `updated_at`;
   - the MR's head sha at fetch time;
   - for line comments, `old_line` and `new_line`, not one line;
   - each thread's resolved flag, not resolved threads left out (it fetches with `--state all`: a thread resolved but never answered is still a point raised).
2. One item per point works, but order alone breaks when the bot renumbers. Keep the bot's own label or number, and the point's first line, with each item.
3. Not enough:
   - an edited note needs an `updated_at` check;
   - a new reply in an old thread brings back the whole thread;
   - a reopened thread is a resolved-flag change.

   Also store the head sha with each fetch: a new bot pass usually follows a push.

## Plugins Dev Beta (backoffice, AI and human reviewers)

1. Also needed:
   - the MR's current head sha;
   - each note's id and URL, so a reply can point back;
   - for line comments, old or new line;
   - the MR's description: the human reviewer's design questions needed the MR body to answer.
2. One item per point by order works. Keep the bot note's raw body too, as a fallback when its numbering isn't clean.
3. Not enough: compare `updated_at` too, since a reviewer editing after the reply is a real case, and include threads whose resolved state changed.

## Synthesis, proposed to Fable

| Ask | Who | Proposal |
|---|---|---|
| Change detection: edited notes, new replies in old threads, reopened or newly resolved threads | all three | `review-fetch.sh` compares with the previous fetch of the same change, whose file the log already pins. A thread is `new` (unseen id), `changed` (a new note, a note's `updated_at` moved, or `resolved` flipped) or `seen`. Each thread is returned whole. Only `new` and `changed` reviewer threads are judged; `seen` ones are context. |
| Resolved threads kept, with the flag | Alpha, Gamma | Keep them, with `resolved`; one resolved but never answered is still a point. |
| Note id (and discussion id) | Alpha, Beta | `id` on each comment. The URL is derivable (the change's URL plus the note id), so it isn't stored. |
| `updated_at` per note | all three | `updated` on each comment. Its reader is the next fetch's comparison. |
| Head sha at fetch | Alpha, Beta | Already the event's `head`. |
| Old or new line | all three | `old_line` and `new_line` as the host gives them, both optional, in place of `line`. |
| The commit a comment sits on | Gamma (base, head and start shas) | `commit` (the position's head sha) against the event's `head` tells "outdated". Base and start add nothing a reader uses. |
| The MR description | Beta, Gamma | Already pinned with `remote-change.fetched`. external-review also takes the `change` ref, so the reviewer gets it. |
| The bot's own numbering | Alpha, Beta | Report side, not fetch side: an item's `item` label is the reviewer's point label as the bot wrote it. The raw note body is already the comment's `body`. |
| `line_range`, code suggestions | Gamma | Left out for now: both are in the body or covered by the start line. No reader yet. |

## Fable's alignment (`reports/remotes-workers-fable.md`), adopted

- **Change detection (row 1) changes.** A fetch is not a judgment. If "seen" meant "in the last fetch", a second fetch, or a review job that died, would mark threads nobody judged as seen: the missed review the workers suffer today. So:
  - `review-fetch.sh` stays plain: what the host says, with `id`, `updated` and `resolved`, and no memory.
  - The external-review job compares this fetch with the one the last handed-in external review of the same change read. Resolve fills that ref from the log.
  - The reviewer's facts script works out `new`, `changed` and `seen` from the two pinned files.
- **The change ref:** main doesn't name it. `remote-review.fetched` already names its change, and resolve follows it.
- The other rows and the rejections stand.
- The threads shape goes to the owner only once GitHub's real replies are in: one shape from both hosts, at once.
