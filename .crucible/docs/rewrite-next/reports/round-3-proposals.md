# Report schemas, round 3: the owner's proposals, to verify

By Dev Beta. These came out of the owner's reading of `report-schemas.md` (draft 2). The spec is unchanged until they are verified:
1. by the PS Observer's workers, for fit with real work;
2. by the Crucible Fable Reviwer, with the workers' opinions.

The flows these touch are drawn as timelines in `event-timeline.md`, which uses the proposed names.

## The proposals

1. **One `noticed` field replaces `found` and `handoffs`.**
   - **Where:** build (§1), test (§9) and code review (§5).
   - **The owner's reasoning:** a security concern is something the builder, tester or reviewer noticed. A handoff is something a reviewer noticed outside its own lens. One field covers both.
   - **Two optional flags keep what the old fields did:**
     - `security: true` keeps the security floor: the card always shows it in full, and main hears about it before anything else is offered. Its `text` names the kind of thing, never its value.
     - `for: "<lens>"` keeps the routing: the next round gives it to that lens. This replaces handoffs.

   ```json
   "noticed": [
     { "at": "src/upload/Auth.kt:17", "text": "the token is refreshed on every call, outside this task" },
     { "at": "config/dev.env:3", "text": "a hard-coded cloud access key", "security": true },
     { "at": "a.sh:9", "text": "evals user input", "for": "security" }
   ]
   ```
2. **The test-plan event names** (§3, §4):
   - `test-plan.submitted`: the planner hands in the draft. "Submitted" keeps meaning "the agent handed it in", as for every job, and doesn't suggest it is in front of the human;
   - `test-plan.challenged`: the challenger's result (was `challenge.submitted`);
   - `test-plan.updated`: the rework, answering each challenge with `applied` or `cannot` (was a second `plan.submitted`);
   - `test-plan.approved`: the human's yes at the plan gate.

   The plan is done when every challenge key is answered in a `test-plan.updated`, or at once when the challenge raised none.
3. **No `files` in `build.submitted`.** The changed files are read from the commit. Working commits are never rewritten, so the commit is a stable source.
4. **The report path is back in every submission event** (`report`). A path you can see beats a rule you have to know; it's how the reviewer's job finds the builder's report.
5. **External review: a finding sits inside its item.** A `valid` item carries its `finding`, and there is no separate `findings` list, so no rule is needed to link the two:

   ```json
   "items": [
     { "thread": "n11370", "item": "F-03", "judgement": "valid",
       "finding": { "severity": "medium", "realism": "realistic", "at": ["src/upload/Client.kt:55"],
                    "claim": "the timeout isn't applied to the retry", "suggestion": "pass the timeout into retry()" } },
     { "thread": "n11370", "item": "F-04", "judgement": "rejected", "reply": "The retry is capped at src/upload/Client.kt:42." }
   ]
   ```
6. **`answers` keeps its name,** for the fixer's reply to each finding and the reviewer's reply to the fixer.

## What we ask

- **The workers:** does each proposal fit your real work? What would break? Write `reports/worker-<name>-r3.md`. Short is best.
- **Fable,** after the workers: do these pass your reader test and the constitution? And the timeline: does it show the flows as the spec defines them? Write `reports/schemas-fable-3.md`.
