# Job kinds: one skill per kind, and per-kind `*.defined`. Fable's opinion (2026-11-27)

By Crucible Fable Reviwer, for the owner. The owner's go is the only go.

**What I read:** `reports/job-kinds-brief.md`, `spikes/dispatch/job-shapes-final.md`. In `new-rewrite/domains/software-development/core/`: the `agent-jobs` rules and its two jq modules, the ten `*.submitted` rules, and the agents' `submissions/<kind>.json` files.

**Not done:** nothing was run. I did not read the event-jobs spike (the arbiter) or task #21 (live validation).

## Verdict

| Question | Answer |
|---|---|
| One piece per kind | **Yes**, if a kind's piece is a declaration and a few lines of prose, not machinery |
| Per-kind `*.defined` events | **No. Keep one `job.defined`.** It doesn't break the chain; it costs every reader and buys little |
| Foreign review | Not a kind: a review with other inputs |
| External verdicts | A kind of its own, kept narrow |
| Arbiter, live validation | Not kinds yet |

## 1. Per-kind pieces: right, with one condition

**A kind is a real unit.** It is one thing asked of one agent base, with its own report handed back. The framework already treats it that way: each kind has its own file `agents/<base>/submissions/<kind>.json`, found by the kind's name, with no list anywhere.

**The condition: a kind's piece holds what differs, and nothing else.** That is:
- what the job needs from main (which input refs, a tree or not, a range or not);
- how its own inputs are filled, where a script is needed (a review's range from the tree's head; a fix's targets from `fix.chosen`);
- a few lines for main: what the job is for, what it needs, what comes back.

**Everything a job does as a job is shared, in one `jobs` component:** resolve, define, the door, assign, end, the start hook, and the counting (iteration, round, cap, one writer per tree). No kind copies or wraps any of it.

**Two tests that tell whether the split is right:**
1. Adding a kind adds its own folder (and its agent-side files) and edits nothing shared.
2. No kind's name appears in shared code. Today `iteration.jq` says `kind == "build"`; that becomes a fact the kind declares ("opens an iteration").

**The risk is in the prose, not the folders.** Eight skills each telling main what to do next is a rule nest in eight pieces. A kind's prose should never say when to run it or what follows it; the adaptive flow and the human decide that. If the resolve script already prints what a job still needs, most kinds need about five lines.

**One declaration per kind, not two.** The agent side already declares each kind (`event`, `commit`, `writes`). A second declaration on main's side for the same kind would drift. The shared part needs only a few facts about a kind (does it write to the tree, does it open an iteration, what it needs); decide once where a kind says them, and have the door and resolve read that.

## 2. One `job.defined`, not one event per kind

**Beta's premise doesn't hold in today's code.** "If every kind writes `job.defined`, one rule knows every kind." The rule that exists (`job.dispatched.jq`) serves ten kinds and names one, `build`. It checks the frame and the counting, and says so in its header: which job needs which input "is the dispatch's to decide". A rule needs a kind's facts, not the kind.

**What a kind needs comes in two sorts, and they belong in different places:**
- **Needs that can't go stale** (a review has a range, a fix has targets, a build may cut). These are the kind's own. Resolve checks them before the card, and define writes exactly the resolved file the gate's hash names. They don't need the rule.
- **Counts that can go stale** (iteration, round, cap, one open writer per tree). These span every kind on a tree. They must run at the write, in one place, over all jobs.

So the part that must be in the rule is exactly the part that is not per-kind.

**What per-kind events would cost:**
1. **Every reader has to join them again.** The nine invariants, the door, assign, the audit, the reader of step 6 and a human reading the log all ask "the jobs on this tree". With one type that is one select. With ten it is a suffix match or a guess from the body's shape.
2. **The precedent shows it.** The ten `*.submitted` rules are the same single line each (`jobs_submission_problems`). And because nothing can list their types, `jobs_finish` finds a submission by its body having a `report` object. That works, and it is the fragile spot I would not make a second time.
3. **The kind would be said twice:** in the type (`build.defined`) and in `body.kind`. Drop one and readers parse type names for meaning; keep both and a rule must hold them equal.
4. **The separation would be in name only.** Each per-kind rule would be one line calling the shared module with the kind's facts. The module is still the one rule; it only moved.
5. **It reopens what is proven.** Four runs ran one `job.defined`, and the owner approved that shape. A change of type is a new shape for the owner and a rerun of the audit.

**Why `*.submitted` per kind is still fine:** a submission belongs to its agent and its report, and nothing counts across submissions except "the job finished". A definition is the opposite: everything counts across them.

**What does not break either way.** The stale-iteration race stays closed under per-kind events too, as long as each rule runs the shared counting under the lock. So this is not a correctness call. It is a call about where the join sits, and one type keeps it in the log instead of in every reader.

**If the owner prefers per-kind events anyway,** three conditions:
- one shared def is the only place that knows how to find a job in the log;
- the kind lives in the type only, and `body.kind` goes;
- the tree run's audit is rerun on the new shape before step 1 is built.

**One thing to settle with it:** the chain in `job-shapes-final.md` says `job.submitted`; the framework has per-kind `*.submitted`. Say which stands.

## 3. The kinds

**What makes something a kind:** a distinct ask and a distinct report. The same ask with other inputs is not a kind.

| Proposed | Verdict |
|---|---|
| Build, test plan, test, test-plan challenge, review | Kinds. All five exist today |
| Build fix and test fix as two | **Two kinds.** Different agents, write scopes and reports; already two events |
| Re-review | The review kind with earlier findings in. Not a kind |
| Test-plan revision | The test-plan kind again, with the challenges in. Not a kind. (Today's `test-plan.updated` then folds into it or stays; small) |
| Foreign review | The review kind on a tree cut from a ref, with no iteration. Not a kind, no skill |
| External verdicts | **A kind.** Comments in, a verdict per comment out; a different ask and report |
| Arbiter ruling | **Not yet.** No arbiter agent exists here, and a decline goes to the human today (`sent_back`). A kind with no agent and no failure behind it is a rule ahead of its need |
| Live validation | **Not yet.** Not designed. Don't hold a place for it |

That is eight kinds: build, build-fix, test-plan, test-plan-challenge, test, test-fix, review, external-verdict. I see none missing.

**External verdicts, kept narrow.** The kind is the judging only. Fetching the threads and posting the replies are tracker pieces, and posting is an outward write behind the human's consent. If the kind's skill takes those in, it stops being a job kind and becomes a flow.

## 4. Against the constitution?

- **Floating pieces:** met by per-kind folders with shared machinery. Per-kind events add nothing to it.
- **Lean:** eight more skills in main's list, beside the thirty plugins that must become visible. Keep each description to one line, and check whether a kind needs to be a skill main loads at all, or only a folder the scripts read. I would start with folders and add prose where a run shows main lacking it.
- **No micromanaging main:** the risk named in section 1. A kind's prose that says what follows is the old pipeline, cut in pieces.
- **No rule without a failure:** the arbiter and live validation.

## 5. For the owner

1. **One `job.defined`, or one event per kind.** My lean: one.
2. **Is a kind a skill main loads, or a folder the scripts read, with prose only where needed.** My lean: the folder first.
3. **Where a kind states its facts once** (agent side, where it does today, or main's side).
