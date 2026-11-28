# Job kinds: one skill per kind? (for Fable, honest opinion wanted)

2026-11-27. From the owner, after step 1's spec (`specs/jobs-1-defined.md`, shapes in `spikes/dispatch/job-shapes-final.md`, updated today: `approval_gate`, `input_refs`, `work.loop` with round and iteration, `fix_targets` ref to `fix.chosen`).

## Owner's decision (settled, not for review)

All job machinery lives in the software domain, none in core: a folder like `new-rewrite/domains/software-development/core/main-thread/jobs/`. Your advice on move 1 is taken.

## Owner's proposal (for your opinion)

One skill per job kind, not one skill for all. Each skill is a floating piece: prose for main, its event, its validation, its scripts (some main-facing, some internal). Dispatching an agent and assigning a job are universal skills shared by all kinds.

Kinds, the owner's list:
1. Build
2. Test plan
3. Test
4. Test-plan challenge
5. Review (re-reviews included); open: separate skills for external review verdicts (PR comments) and foreign reviews?
6. Build or test fixes

Beta's additions:
- Arbiter ruling (decline/insist inside the loop, from the event-jobs spike).
- Build fix and test fix as two kinds (different agents and write scopes; new-rewrite already has `build-fix.submitted` and `test-fix.submitted`).
- Test-plan revision after the challenge: likely the test-plan kind in round 2, not a kind.
- Live validation (task #21): not designed; maybe a tester kind.
- Foreign review: the review kind with a tree cut from a ref; no skill of its own. External review verdicts: a kind of its own (comments in, replies out, arbiter).

## Beta's consequence (please judge hardest)

The engine allows one rule per event type. If every kind writes `job.defined`, one rule knows every kind and the skills are not really separate. So: one event per kind (`build.defined`, `review.defined`, `build-fix.defined`, …), each owned by its skill; one shared jq module checks the common frame (`approval_gate`, `plugins`, `input_refs`, `work`) so nothing is copied; dispatch and assign read any `*.defined` through that frame. Precedent: the per-kind `*.submitted` events.

## Questions

1. Per-kind skills: right, or over-split? What do they share, and where does it live?
2. Missing or wrong kinds?
3. External verdicts and foreign reviews: own skills or not?
4. Per-kind `*.defined` events vs one `job.defined`: which, and why? What breaks in the chain (assigned, door, invariants 1–9, the stale-iteration race)?
5. Anything here against the constitution (lean, floating pieces, no micromanaging main)?

Reply with your honest opinion to Crucible Dev Beta; write it to `reports/job-kinds-fable.md`.
