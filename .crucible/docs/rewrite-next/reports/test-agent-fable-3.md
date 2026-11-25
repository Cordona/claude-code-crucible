# The test agent, version 3: final check (2026-11-24)

By Crucible Fable Reviwer, for the owner. Talking only; the owner's go is the only go.

**What I read:** `test-agent.md` version 3 in full, and the last section of `decisions.md`, against `test-agent-fable-2.md`. I ran nothing.

## Verdict

**Version 3 matches my verdict and the owner's two decisions, and nothing new crept in.** Every change I asked for is there, and no field was added beyond `names`.

**Four small corrections before building.** One is a real conflict between two rules; the others are wording and proof cases.

## The four corrections

1. **A failed `mutation` gate collides with the builder's gate rule.**
   - The shared rule says a `fail` whose failures aren't known needs a `gate_red` blocker.
   - Section 3 says a surviving break is the test reviewer's call, so no blocker.
   - Both can't hold. As written, a tester that honestly reports a survivor is refused until it adds a blocker, and a blocked job is offered an answer to the blocker, not a review.
   - **What I'd do:** say in the rule that it covers the checks of the tree, and that `mutation` is left out of it. Its `failing` list holds what survived, and the reviewer reads it. That is one line in the shared rules, and it follows the owner's decision as written.

2. **The production-bug example has no `mutation` gate,** so the spec's own rule would refuse it. Add it as `not_run`, with the reason that the tests are red.
   - Say also whether a tester's fix must list the gate. The rule's table covers both; the decision says "a test report". I'd require it on both, since a fix changes tests too.

3. **The refusal line for an unplanned file the build changed** says "name it in the plan". A tester in a test job can't change the plan, so it can't act on that line alone. That wording came from me. Better: "undo it, and say what you need in a question or a `cannot` blocker".

4. **Two cases are missing from section 10,** both rules this round added:
   - a planned file the build also changed is accepted (the planned file wins);
   - a test report without the `mutation` gate is refused.

## Checked and found as agreed

| Point | In version 3 |
|---|---|
| The approved plan is the scope; the planned file wins | section 5 |
| `production_bug` anywhere outside the plan's own files | sections 3 and 5 |
| `covered_by: nothing: <why>` | the action table |
| `names` on `modify` and `remove`; `name` on `add` | the action table |
| `guards` optional on `modify` | the action table |
| A support entry may name a folder; the rest is text in `what` | the fields table |
| The examples run with a filter | section 2 |
| `mutation` as a gate, no per-test fields | section 3, as the owner decided |
| `test_red` folded into `gate_red`; no `side`; no `plan` in the event | sections 3, 4 and 7 |
| A blocked job still commits | section 6 |
| The `testing` standard's check left to the dispatch talk | section 6 |
| The shared report rules in a neutral home | section 9 |
| Report folders by job kind | section 1 |

**One thing to keep in mind when building, not a change:** adding `mutation` to the shared gate list lets a builder list it too. That is fine, and nothing should require it of a builder.
