# Dev Beta [Backoffice]: the reviewer spec against real reviews

Read only. Sources:
- internal reviews on PSWS-1728, 1815, 2123 and 2219;
- external reviews of our MRs: !37 (one bot note, 9 points) and !29 (an AI note numbered §1–§10).

## 1. Can a reviewer say everything? (review)

Yes. Round 1's asks are all in:
- `notes`: PSWS-1728's "accepted documented deviation: recordingGateway() partially mocks the class";
- `out_of_scope`;
- `relates_to`;
- `@where:` for a related repo, as with PSWS-1713's bearer header;
- `noticed.for`: PSWS-1728's "audit integrity" handoff to observability.

**One gap: `relates_to` on a deleted line.** PSWS-2219 removed everything for a matview. A finding there reads "a caller still uses the deleted view": its `at` is an unchanged caller, and the line it relates to is a deleted one. Say that `relates_to` accepts `-path:N`, and that a deleted line counts as changed.

## 2. External review

**The six verdicts cover our threads:**

| Real point | Verdict |
|---|---|
| !37 N-1: true, but intended and documented | `rejected`, with the reply naming where it's documented |
| !29 DISCUSS | `deferred` with a `note` |
| !29 §9, §10 ("no issue", said by the bot itself) | `noted` |
| !29 §2, fixed after the review | `valid`; the later reply was "§2 — fixed in 51e2171" |

**The two reply offers match.** On !37 we posted the 9 replies only after the fix was pushed, one per point under the one note, each headed by its point.

**Splitting into items matches,** with the bot's own labels (F-01..F-05, N-1..N-4).

**Two things break:**
1. **One lens per job doesn't fit (§14 question 6).** !37's one note held points for 4 lenses: PHP ×4, observability ×2, security ×2, performance ×1. One external-review job with one lens means:
   - a PHP reviewer judges the security points;
   - their findings get stamped `PHP-NN`.

   Suggest an optional `for: <lens>` on a valid item, as on `noticed`. The stamp uses that lens, and main may offer that lens a second look. A security item must keep the security floor.
2. **A pre-existing point the human still wants fixed.** !37 N-4 was true on main too, so it was `deferred`. Then the user chose to fix it anyway, because it was cheap (eb49b45, info→debug). `deferred` only leads to the replies gate, never to the fix choice. Suggest the replies gate can send a deferred item to the fix choice. A gate option keeps the report as it is.

**Also, for the remote's spec:** after our replies, a re-fetch of the MR's threads holds our own notes. Drop them in the fetch, or every one must be judged `noted`.

## 3. Foreign review

No real case: we've only read peers' core-api changes we depended on, and left no comments. One remark for the comments gate: GitLab can anchor an inline comment only on the MR's diff. A finding with `relates_to` or `out_of_scope` has to post as a general note.

## 4. The re-review statuses

`fixed`, `open`, `agree` and `disagree` cover what we saw:
- PSWS-1815's item A was half fixed, which became `open` with a reason;
- PSWS-1728's 78-test repair was `fixed`, with notes.

A fix that breaks something else is a new finding or `reopens`, and both exist.

## 5. The plan challenge

It fits:
- `path::helper` covers PSWS-1728's `assertAuditedOnce` level argument;
- `change` now covers a wrong fact;
- PSWS-1815's plan grew from 14 to 26 tests through `add` challenges.

## 6. Rules that would refuse a good review

Only the deleted-line `relates_to` above. The 200-character one-line limit fits our findings, and the 1,000-character reply fits our replies.

## 7. The open questions (§14)

- **Q1, slim bodies:** agree.
- **Q6, the lens for a valid external finding:** per item, not per job (see 2.1).
- **Q9, a separate arbiter:** agree. It also needs a way to hand an item to the human: PSWS-2123's point 3 became a follow-up ticket on the user's call.
- **Q10, one agent type with the lens in the job:** agree.
- **Q12, holding the lock from the stamp to the event:** agree. Readable IDs matter in MR replies.
