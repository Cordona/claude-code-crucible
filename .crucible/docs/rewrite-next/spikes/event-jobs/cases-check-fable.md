# Stage A cases: check before the scripts (2026-11-23)

By Crucible Fable Reviwer, for the owner. Reading only; I ran nothing, the fixtures included.

## What I read

- `contract.md`, `cases/open-rules.md`, and the spec's changed lines on a death.
- **All 60 cases:** `why.md`, `command` and `expect.json`.
- **20 fixtures line by line,** and their seq numbers counted by hand: a1-05, a2-02, a2-05, a2-07, a2-09, a2-10, a2-12, a2-14, a5-04, a7-04, a7-06, a8-01, a9-02, a9-04, a9-05, a9-06, a11-01, and through their shared opening a1-04, a2-13 and a8-02.
- The other 40 I judged from `why.md` and the expected output only. If an expected seq is off by one in those, I would not have seen it.

## Verdict: sound, with one wrong expectation and one hole that matters

- **The expected outputs are right by the design** in every case I checked against its fixture, except a2-10.
- **Of the 61 rule choices, four are wrong** and five contract gaps should be closed before the scripts are written. The rest are right or harmless.
- **The hole:** `--gate` is main's own word that a gate covered a dispatch. With it, main can pass any dispatch, including one past the cap. It undoes the refusals this stage is proving.
- **Section 4 is covered.** Nine more cases are worth adding; none is large.

## 1. Expected outputs

**Right, and worth saying why:**

- **The loop counts match the old flow.** a2-05 runs decline, insist, decline again, arbiter, ruled `fix` in two rounds, leaving one for the fix. That is D10's count with a cap of three.
- **a2-14 is exactly the rule:** the key declined for the first time goes to the re-reviewer, the deadlocked one only to the arbiter, one arbiter, last in the set.
- **a2-12 is sequential,** production first, which is also what the busy rule forces on one tree.
- **a2-01 against a2-07:** no targets at the last round is `clean`, targets left is `cap`.
- **a10** refuses each repeated step and leaves the scan unchanged.

**Wrong: a2-10, after the human's stop.** The fixture stops the loop while a re-reviewer is working, the reviewer then submits, and the expected output is empty. By that reading:

- a finished report is never merged, so the findings keep the status they had before the fix;
- no end card and no choice gate is ever owed, so the root goes silent with work on it;
- a fix job in flight at the stop would leave a commit nobody reviewed and nothing that says so.

"Stop" should mean **nothing more is dispatched**. So after `loop.stopped`:
- `fix`, `make-round` and `replace` are never owed;
- the merge of a complete round is still owed (it dispatches nothing);
- then the end card is owed, with a reason `stopped`, which `loop.ended` doesn't have yet;
- a fix that submits after the stop shows as the fact "no review".

a2-10 should expect the merge of round 13. Its name stays true: nothing is started.

## 2. The rule choices

### Wrong

1. **`--gate` as a flag (a9).** A gate must be an event, written by the lab's gate recorder (`choose.sh`), and the dispatch names it as its `approval`. Then `approval` is never `null`, "no approval" is checkable for every dispatch, and a9-05 can't be passed by adding a flag. This is the constitution's own example of an invariant in code: a gate before dispatch.
2. **The approval of the challenge and the rework is "the first test-plan job's seq" (a7-03, a9-09).** A job is not an approval. It follows from 1: both are covered by the gate event that approved the test-plan step.
3. **Main passes `--root` (a1-05, a8-01, the dispatch flags).** The claim "roots never mix" then rests on main typing the right number. The script can derive it: a job on a tree takes that tree's root, a job in a round takes the round's, a fix takes its merge's. Only a first build on a new tree has none.
4. **After `loop.stopped` nothing is owed (a2-10).** Section 1.

### Right, with a note

- **A cancelled slot is not replaced (a3-03).** Right as the default; it is my own wording.
- **Gave up or died owes a replacement outside a loop too (a3-01, a3-02).** Right, and it is D9's silent re-seat. With 1 fixed, the round's own gate is what covers it.
- **Own-commit is checked before type-misfit (a9-02).** Harmless. With these agent types the first can only happen together with the second.
- **A challenge round has no merge (a7-03).** Right. See gap 5.
- **Fix side by the finding's kind (a2-12).** Right: it is O2's rule.
- **An arbiter-only round counts against the cap.** Right: see a2-05 above.
- **A death is "assigned in another session" (a11).** Right as a rule, on two assumptions that only a live run can show: that a reopened session has a new id, and that no second session works on the same effort. C10 decides the first. The rule also misses a job dispatched in the old session and never assigned; treat it the same way.

All the other choices (the `owes.sh` fields, `since`, the fact words, the ID form, the merge listing every finding of the root, the verdict rule, what "carry over" and "new" mean, the slot order) are right.

## 3. Contract gaps to close before the scripts

1. **A re-reviewer isn't told what the fixer answered.** `earlier` carries `{id, status, title}`, and the status is `open` both for a key reported done and for one declined (a2-05, a2-14). The reviewer can't know whether it judges a fix or a decline, and the stop check can't apply D7's rule (done: fixed or open; declined: withdrawn or insisted). Add the fixer's answer to each entry.
2. **`build.submitted` carries no files.** So the cover of a re-review, "the fix's files plus the chosen findings' files", can't be tested: every cover case uses a fix with no commit. The stop check knows the commit's files; put them in the event, and add one case with a real fix.
3. **A finding from an external review carries no thread** (noted in open-rules). Without it the replies can't be traced to their findings. D14 has it on every concern.
4. **What ends each gate step is only half stated.** `choose` is ended by `fix.chosen`; `replies` and `comments` by `pr.posted`. Missing: what ends `plan-gate` (the human's approval of the plan has no event), and what records "fix nothing" after a merge. Without the second, `choose` is owed for ever on a review the human accepts as it is.
5. **Who gives a challenge its key** (noted in open-rules). With no merge, the stop check of the challenge job is the natural place.

## 4. Missing cases

| Case | Why |
|---|---|
| The production fix submitted and a tests key still pending, no test fix dispatched yet → `fix`, side `tests`, is owed, not a round | a2-12 only shows the wait once both exist |
| After `loop.ended` with reason `cap` → the choice gate is owed again; after `clean` → nothing | The loop's last step, D11 |
| A stopped loop with a fix in flight → the fact, no round | Section 1 |
| "Fix nothing" ends `choose`; on an external root the replies are then owed | Gap 4; an external review where every thread is rejected has no loop at all |
| A fix job that died → `replace`; its second death ends the loop | Every death case is a reviewer; a dead builder leaves a dirty tree |
| A waiver takes a key out of the next targets | A finding closes by a report or a waiver; no case uses the event |
| A gate-covered dispatch with no gate event → refused | Follows from wrong choice 1 |
| An external round's cover: a thread with no file goes to the tech reviewer | No `round.sh` case for kind `external` |
| A re-review cover with a real fix: its files plus the chosen findings' files | Gap 2 |

One cheap strengthening: in a2-02, add a new high finding with realism `edge-case` to the re-review. The harvest must leave it out; today only `choose.sh` is tested on realism.

## 5. A rule for after the scripts exist

The expected outputs were written first, as I asked. Keep that worth something: once a script exists, any change to an `expect.json` is listed in the results with its reason. A case made green by editing its expectation is the false pass this stage exists to prevent.
