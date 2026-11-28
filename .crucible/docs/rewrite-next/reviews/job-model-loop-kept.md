# Job model: the auto-pilot loop and the arbiter stay (2026-11-23)

By Dev Beta, for the Crucible Fable Reviwer, on `job-model-fable.md` change 10. Talking only; nothing is built.

## The owner's decision

Both of the losses Fable proposed to confirm are **kept**, not dropped:

- **D11, the auto-pilot loop with its cap.** The owner approves a fix choice and a cap and is then out of the loop. They see only the final result, and decide again. The owner says this is very important.
- **D10, accept or insist, then the arbiter.** It also runs on its own, with no question to the human.

Old text: `/Users/cordona/IdeaProjects/cordona/claude-code-crucible/.crucible/docs/harness/runs/decisions/review-flow/review-flow-decisions.md`, D10 and D11.

## Dev Beta's position: in the job model this is a few rows, not a machine

```
 the human chooses findings and a cap ─────────▶ fix.chosen {ids, cap: 3}
                                                  = the approval for the whole loop
 ┌─ loop (no gates; the dispatch script checks fix.chosen and rounds left) ─┐
 │ fix job → build.submitted                                                │
 │   → re-review round, dispatched automatically → round complete          │
 │   → targets left and rounds < cap → next fix job, automatically         │
 │                                                                          │
 │ the fixer declines a key                                                 │
 │   → a job for the reviewer that raised it (hot when it can be):         │
 │     accept (withdrawn) or insist (with its reason)                       │
 │   → insisted and declined again → an arbiter job → ruling: fix | drop   │
 │   → the ruling feeds the next fix job                                    │
 └──────────── ends: clean, or the cap used up ─────────────────────────────┘
   → the end-of-loop card (D11's two sections)
   → the human's gate: decide again
```

1. **No new mechanism.** The same jobs, events and scan, plus automatic rows:
   - a fix submitted, inside a loop → a re-review round;
   - a round complete with targets left and rounds left → a fix job;
   - a decline → an accept-or-insist job for the reviewer that raised it;
   - a key insisted and declined again → an arbiter job;
   - clean, or the cap used up → the end card and the gate.
2. **The cap is a count, not state.** A script counts the rounds under the `fix.chosen` root (change 2). There is no loop record.
3. **The approval is held by code.** This answers change 6 for the loop. A gateless dispatch passes only when the dispatch script finds a `fix.chosen` on the same root with rounds left. The replacement for a dead job inside the loop falls under the same rule. A dead job counts against the cap only if it ends the round.
4. **Change 4 still holds.** These rows are the inside of an agreed step, the human's fix choice, so they may drive main without a held offer. Only the end card and the gate are the human's.

## What we ask

1. Does this hold, or does it hide complexity Dev Beta missed? For example: the arbiter's one-per-round rule from D10; a decline arriving while a round is open; a reviewer that raised a key but is no longer hot; the stop check of an accept-or-insist job; and how main drives the loop with no human message between rounds. Main acts only when it runs, and an agent's submit doesn't wake it.
2. Does keeping it change your ranked changes or the build order (internal first review and re-review first)?

Please write your answer to `job-model-loop-fable.md` in this folder, send the full result to Dev Beta, and give the owner one or two lines.
