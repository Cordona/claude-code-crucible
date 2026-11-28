# Remote reviews, the whole design again: Fable's re-review (2026-11-27)

By Crucible Fable Reviwer, for the owner. The owner's go is the only go.

**What I read:** `specs/jobs-remote-reviews.md` in full, `spikes/remotes/gitlab-findings.md` in full (for the first time), and `spikes/remotes/github-findings.md` (earlier today).

**Not done:** nothing was run. I did not read the owner's sample files behind the GitHub findings, the reviewer's facts scripts, or `events-view.sh`.

## Verdict

**Approve, with five changes. One of them takes back advice I gave.** The design is sound as a whole: a plain fetch, facts in the log, the comparison in the reviewer's own script and bounded by the job, one kind-file word, nothing new in `jobs/track`. The order (scripts proven on real replies first, then the events) is right.

| Change | Section |
|---|---|
| Put GitLab's commit for a note back; I was wrong to ask for it out | 1 |
| Section 3's table is older than the findings; keep one mapping | 2 |
| The validation text doesn't match the order now agreed; name what stubs can't prove | 3 |
| Say how an external review reaches the change's description | 4 |
| The owner approves the three shapes after the scripts' runs, before the events | 5 |

## 1. The commit on a GitLab note: I take my change back

**I asked to drop the derived commit for notes with no position, calling it a guess. Having now read the GitLab findings, that was wrong.**

On this GitLab the main form of a review is one note with no position, holding many points that cite `path:line` in the text. Every AI review seen is like that, and some human ones. After the fix is pushed, those line numbers no longer match the head. Without a commit, the reviewer reads "file X, line 120" against the wrong version of the file. The event's `head` doesn't help: it is the head at the fetch, not when the note was written.

**The versions list answers it, and it is one read per change, not per note:** the commit is the head of the latest version pushed before the note. It is an inference, but a sound one, and it is the field the reviewer needs most in the commonest case.

So: `commit` as the host gives it where it does; on GitLab, for a note with no position, from the versions list; absent only where neither exists (a GitHub conversation comment). The field's line in the spec should say which of the three it is, so nobody takes the inferred one for the host's word.

## 2. One mapping, not two

**Section 3's table predates the real replies and now disagrees with the findings and with section 2:**
- step 2 of `review-fetch.sh` says "every open review thread"; section 2 keeps resolved ones, flagged;
- the table takes a line thread's commit from the comment; the GitHub findings say it comes from the review the first comment belongs to;
- it lists a login ending `[bot]`; the findings say the host's own type is enough.

Let section 3 point to the two findings files for the mapping and keep only what is a decision (`--bot`, what is left out). Two tables will drift again.

## 3. The validation

**The text still says GitHub live on the owner's login; the order now agreed says GitHub on stubs from the owner's scrubbed samples.** Align the section with the order. The stubs' source is those samples, not "captured from public PRs".

**Name what the stubs can't prove.** A stub answers whatever it is asked. So the stub runs prove the mapping from GitHub's reply to the threads file; they do not prove that the query the script sends brings that reply back, or that paging works. Say so in the results as not proven. One read-only call on a public pull request would close it; whether to make it on the owner's login is the owner's call, not ours.

**GitLab live:** the owner names the merge requests, as written. Good.

## 4. The description for an external review

The workers needed the change's description to answer a human reviewer's design questions. Section 5 gives it to the foreign review only. Add the line for the external review: the reviewer's facts follow the review ref to its change and read the pinned description from there. No new ref, and main names nothing.

## 5. When the shapes are approved

Scripts first is the right order because the runs are the evidence for the shapes. Then say the gate plainly: after the scripts' runs, the owner sees the two events and the threads file as real output, and approves them before the rules are written. That is the owner's rule for JSON shapes, placed where it costs least.

## 6. What I checked again and still agree with

- **The fetch keeps no memory;** new, changed and seen come from the reviewer's facts, against the last external review handed in before this job was defined.
- **Resolved threads kept;** on GitLab resolution says little anyway (plain notes can't be resolved), so the comparison by ids and edit times is what carries the second pass.
- **The opener from the first comment;** threads the change's author opened stay as context. The findings show they hold the fixer's account, which the reviewer needs.
- **`--bot` optional, inherited by a later fetch;** GitHub needs none.
- **`range` as `"tree"` or `"change"`, resolve filling the cut;** main types no sha.
- **Only git objects added to the human's repo;** no ref, no `FETCH_HEAD`.
- **No author names in the threads file:** nothing reads them, and it keeps other people's names out of the effort.
- **Posting back is not in this step.**

## 7. Smaller points

- **One note, many points.** A thread can be one note with nine findings. "Every judged thread answered" is then true with one answer. That is the report's side and already has the item label; I mention it so the live run looks at whether each point got its own item.
- **The spec's title** still says "draft for Fable".

## 8. For the owner

1. **The one public read-only GitHub call** (section 3): make it, or accept GitHub's query as not proven until first real use.
2. **The three shapes,** when the scripts' runs show them (section 5).
