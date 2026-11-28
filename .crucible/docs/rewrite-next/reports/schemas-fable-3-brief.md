# Report schemas, round 3: brief for the Fable Reviwer

By Dev Beta. The owner's six proposals (`round-3-proposals.md`) and the timelines (`event-timeline.md`) went to the PS Observer's five workers first. Their answers are in this folder:
- `worker-dev-gamma-r3.md`;
- `worker-dev-epsilon-r3.md`;
- `worker-dev-alpha-r3.md`;
- `worker-dev-beta-backoffice-r3.md`;
- `worker-kpi-features-r3.md`.

The owner asks whether you and the workers approve the proposals. Nothing is changed in the spec until you have judged them. Talking only; the owner's go is the only go.

## What the workers say, by proposal (n of 5)

1. **One `noticed` field: accepted, with conditions.**
   - **`security` must be a kind, not a boolean** (5 of 5): `security: "secret" | "instruction"`. A secret means rotate or remove, and is never quoted. An instruction is untrusted text and is never followed. Customer data counts as a secret.
   - **`for: "security"` must imply the floor** (3), or the two flags must be defined apart. The proposal's example "evals user input, for security" would miss the floor.
   - **The floor can't rest on an optional flag the agent may forget** (KPI). Either make the choice required on every entry, or have the stop check scan for secret, host and customer-data shapes and refuse an unflagged hit.
   - **A `for` item needs a stable ID,** so that the receiving lens answers it in its `answers` (Alpha, Epsilon). That was `<seq>:handoff:<n>` before.
   - **`for` must allow `human`,** not only a lens (Epsilon).
   - **A `for` on a builder's or tester's note is an offer, never owed** (Gamma). Lenses run only on an explicit ask. A reviewer's `for` inside a running loop may be owed.
   - **`noticed.at` should allow `@<where>:path`** (Epsilon).
2. **The test-plan names: accepted** (5 of 5). One gap, raised by all five: the human changes the plan at the gate, or after approval ("drop T-3, add a 401 case"). It needs an event, `test-plan.amended` or an `updated` with no challenge answers. Two workers add:
   - a change after approval voids the approval, and only the new or rewritten tests are challenged again (Epsilon, Gamma);
   - `test-plan.approved` carries the digest of the plan the human saw, so the tester writes exactly that plan;
   - and: is `test-plan.approved` a second event beside `gate.answered`, or does it replace it? (Alpha.)
3. **No `files` in `build.submitted`: split.**
   - **Accepted, on conditions** (4): the effort branch is never rebased or rewritten (main is merged in instead); a ref keeps each effort's commits until the effort is pruned on purpose (otherwise gc removes them); the stop check stages only what the job changed, never `git add -A`, because untracked generated files would sweep in.
   - **Rejected** (Epsilon): fast-forward rebases, re-made landing commits and deleted worktrees make a later read from the commit fail. Keep `files`, stamped by the hook; it costs the agent nothing.
4. **The report path: accepted** (5 of 5), on two conditions (Epsilon): it lives in the Crucible space, never in the job's tree; and it never reaches a commit, an MR body or a ticket.
5. **The finding inside its item: accepted,** with cases:
   - **one item holds two defects** (3): allow a split (`F-03a`, `F-03b`) or a `findings` list;
   - **who assigns `item`** when a note isn't numbered: the triage agent or the fetch script;
   - **the same defect in two threads** (a bot's and a human's): `same_as: "<item>"`, fixed once, with both threads replied to (KPI);
   - **a `valid` item needs its reply too, after the fix,** naming the landed commit (4 of 5). So the replies gate belongs after the fix loop and the landing, not at timeline 4 step 6;
   - **a "the human decides" judgement** (DISCUSS) is still missing (Backoffice). `answered` is for questions we can answer ourselves.
6. **`answers` keeps its name: accepted** (5 of 5). The values are validated by the job's kind.

**On the timelines:**
- landing (commit, push, MR) is its own consent step, and the timeline should say so;
- in one repo a correctness review is mandatory before anything lands, so an `[offer]` review is fine only if landing refuses an unreviewed build;
- a reply to a human's release question stays the human's at the replies gate.

## My positions

1. `security: "secret" | "instruction"`, written by the agent.
   - The stop check also scans the `noticed` text and `at` lines for secret shapes, and refuses an unflagged hit.
   - `for: "security"` without `security` is fine: it is a defect for the security lens, not the floor. The two stay defined apart.
   - `for` items get a stamped ID (`<KIND>-NN`, like any finding), so the receiver answers them.
   - `for: "human"` is allowed.
   - A `for` from a build or test job is an offer; from a review in a loop, it is owed to the next round.
   - `@where` is allowed in `noticed`.
2. `test-plan.amended` for the human's change.
   - It voids an approval; only the changed tests are challenged again.
   - `test-plan.approved` is the plan gate's `gate.answered`, under its own name, carrying the plan's digest.
3. Keep `files`, stamped, as Epsilon says; it costs the agent nothing. Also: the stop check stages only the job's changes, and the effort branch is never rebased.
4. As proposed, with Epsilon's two conditions.
5. Items may be split by the triage agent (`F-03a`), and the fetch numbers unnumbered notes. `same_as` is allowed.
   - A `valid` item's reply is written after the landing, from the fix's `done.note` and the landed SHA.
   - The replies gate moves after the landing.
   - Add a `discuss` judgement: the human decides, at the replies gate.
6. As proposed.

## Questions

1. Do the workers' conditions and my positions pass your reader test and the constitution?
2. `files`: keep it stamped, or drop it with the ref and no-rebase rules?
3. Is `discuss` a seventh judgement worth its place (you called six the ceiling)?
4. Does the timeline, with the replies gate moved after the landing, show the flows as the spec defines them?

Please answer in `schemas-fable-3.md` in this folder, send the full result to Dev Beta, and give the owner one or two lines.
