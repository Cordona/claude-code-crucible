# Dev Gamma (Core API, PHP/Laravel, GitLab): the reviewer spec against real reviews

**Sources:**
- our own MRs !402 and !403 (PSWS-2355/2356) and !347, !349 and !352, each with the human reviewer's notes;
- the AI review bot, which runs on every MR (label `ai-review-please`);
- the internal reviewer and test-plan challenge passes on 2355/2356.

## 1. Can a reviewer say everything?

**`review`: yes.**
- `relates_to`, `out_of_scope`, `@core-api:` locations and `notes` all map to real cases.
- Auth API and core-api changes are reviewed together, so `@<where>:` is needed.

**One gap, in the re-review (Q4 below):** "fixed, but the fix broke something else". That is `fixed` plus a new finding. Say that a new finding may name the fix it came from. Free text in `claim` is enough; no new field.

## 2. External review

**The six verdicts cover nearly everything. Three real cases don't fit:**

1. **The same point in two threads.** The bot often repeats a point: once in its summary note, once inline. Two `valid` items would make two findings and two fixes.
   - Proposal: a `valid` item may name another item's finding instead of carrying its own, for example `same_as: "F-03a"`.
   - The merge treats that item differently, so the owner's rule allows a field.
2. **`noted` takes no reply, but this project's rule is "answer every AI review".** Every bot thread gets a reply, even "checked, nothing to do".
   - Proposal: allow an optional `reply` on `noted`.
   - That also covers praise from a person, which we answer too.
3. **A valid point the human doesn't choose to fix** (MEDIUM/LOW left out at the fix choice). Offer 2 drafts replies "from the fix". This item has no fix and still needs a reply, usually "follow-up ticket".
   - Say that offer 2 also drafts these.

**Splitting a thread into items:** matches how we work. The bot's notes carry their own labels, and a human note with two points is split by us.

**Back-and-forth threads.** A human thread often holds our earlier reply and the reviewer's follow-up. The reviewer should judge only the latest unanswered point. Say that the threads file carries the history, and that an item is judged against the last note.

**Moved lines.** The bot comments on the SHA it reviewed. After our push the lines have moved. The reviewer maps the point to head (`at` exists at head), and that's right. Name it in the lens prose, or the `at` check will refuse a good item that quotes the old line.

**The two reply offers:** right. That's how I worked on !402/!403: rejected and answered replies first, then "fixed in `<sha>`" after the push.

## 3. Foreign review

The shape fits.
- **A GitLab limit:** an inline comment can only sit on a line in the MR's diff. A finding whose `at` is outside the diff must be posted as a general note. Leave that to the remote's spec, but the comments gate should show which is which.
- **Severity and realism are our vocabulary, not the author's.** The human edits them at the comments gate. Make sure they aren't posted verbatim.

## 4. Re-review statuses

`fixed`/`open`/`agree`/`disagree` cover what I saw. The common real "can't confirm" case: the fix is only checkable in CI, because the local PHP image is 8.1 and main needs 8.3. That is `open` with a reason, so the spec answers it already.

## 5. Plan challenge

It fits the real passes:
- 2355: three tests approved, no changes, so `{}`;
- 2356: five changes, one extend plus its knock-ons, all `change`.

A code location as `target`, for a missed behaviour, is the case that bit on 2356: a look-alike row the plan lacked. Good.

## 6. Rules that would refuse a good review

- **The moved-lines case in §2:** only if the reviewer quotes the bot's line instead of mapping it. Prose can fix that; no rule change is needed.
- **`noted` with a reply:** refused today; see §2.
- **`relates_to` must be a changed line.** That fits a caller defect. It is wrong when the finding is about something the change *removed*, such as a deleted guard. Make sure `relates_to` accepts `-path:N`.

## 7. Open questions

- **Q1 (slim bodies):** yes.
- **Q2 and Q3 (separate kinds and events):** yes.
- **Q6 (the ID prefix of a valid external finding):** the job's lens works as a prefix. Our bot raises security, performance and correctness points in one pass, though. A security point stamped `PHP-NN` hides from anyone scanning for security.
  - Either let `noticed[].for` route it, so it gets a lens of its own,
  - or say plainly that the prefix tells you who triaged it, not what kind of point it is.
- **Q9 (the arbiter):** a separate agent, yes.
- **Q12 (parallel reviewers of one lens):** hold the lock from the stamp to the event. Readable IDs matter: the human reviewer and I refer to findings by ID in MR replies.

---
*Compiled by Claude Code Crucible Framework on behalf of Ventsislav Stoevski*
