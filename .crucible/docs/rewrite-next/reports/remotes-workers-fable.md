# The Plugins workers' asks on the review fetch: Fable's alignment (2026-11-27)

By Crucible Fable Reviwer, for the owner. The owner's go is the only go.

**What I read:** `spikes/remotes/worker-answers.md` (the three workers' answers and Dev Beta's synthesis). I did not open `gitlab-findings.md`.

**Not done:** nothing was run.

## Verdict

**I agree with the workers on what is needed, and with the synthesis on every row but one.** The workers describe real cases from real reviews, which is exactly the evidence a shape should be drawn from.

**Where I differ: what "seen" is measured against (shift a).** One smaller point on shift (d). And one on timing: the shape waits for GitHub's real replies.

| Shift | My answer |
|---|---|
| (a) Change detection | **The need: yes. Where it lives and what it compares with: differently.** Section 1 |
| (b) Resolved threads kept, with a flag | Agree |
| (c) Comment `id` and `updated`; `old_line` and `new_line` | Agree; each has a reader |
| (d) external-review also takes the change | Agree on the need; no second ref for main. Section 2 |
| Rejected: `line_range`, suggestions, base and start shas, note URL | Agree |

## 1. Change detection: compare with what was judged, not with what was fetched

**The proposal:** `review-fetch.sh` compares with the previous fetch of the same change and marks each thread `new`, `changed` or `seen`. Only new and changed threads are judged.

**The flaw: a fetch is not a judgment.** "Seen" there means "was in the last fetch". But a fetch can happen with no review after it: main fetches twice, or the review job dies and is replaced, or the human looks and decides to wait. The next fetch then marks those threads `seen`, and they are never judged. A missed review is the very thing the workers say happens to them today.

**The simpler shape keeps the fetch plain:**
- **`review-fetch.sh` writes what the host said, and nothing relative.** With `id`, `updated` and `resolved` on it, any two fetches can be compared by anyone. The script stays one act, with no memory.
- **The job says what it compares with.** An external-review job reads this fetch and, when there was an earlier pass, the fetch that the last handed-in external review of this change read. Resolve can fill that from the log, as it fills other refs; main names nothing.
- **The reviewer's own facts script works out new, changed and seen** from the two pinned files. That is where "only new and changed are judged" belongs: it is the reviewer's reading, not the fetch's.

Same result when all goes well. When a job dies or a fetch goes unused, nothing is skipped.

**The workers' three cases all still hold** under this: an edited note (`updated` moved), a new reply in an old thread (a new comment id), a reopened or newly resolved thread (`resolved` flipped). Each thread is still given whole.

## 2. The change's description for an external review

**The need is real** (a human reviewer's design questions needed the description). But `remote-review.fetched` already names its change. The reviewer's facts script can follow that, or resolve can fill the ref. Main shouldn't have to name the same change twice in one job.

## 3. Timing: one shape from two hosts

**Don't bring the owner the threads shape until GitHub's real replies are in.** Everything here is drawn from GitLab. The fields will probably map (resolved, edited time, old and new line), but "probably" is how a shape gets a GitLab accent. The owner is already getting the real responses; the shape goes to them once, with both.

## 4. What I'd keep out

- **The bot's numbering as the report's item label:** fine, as long as it uses the item label the report already has and adds no field.
- **Replying, and who resolves a thread:** the workers' practice is useful for the later posting piece. Nothing of it belongs in this step.

## 5. For the owner

One open disagreement to decide: **change detection in the fetch, against the last fetch (the synthesis), or in the review job, against the last review that was handed in (my lean).**
