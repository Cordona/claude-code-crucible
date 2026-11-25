# The fixes for the three open items: Fable's review (2026-11-25)

By Crucible Fable Reviwer, for the owner. The owner's go is the only go.

**What I read:** Dev Beta's proposal, against the refusal lines and counts I took from the final run's raw events, and the parked attempts' record.

**Not done:** I read no new code; nothing is built yet. I ran nothing.

## Verdict

**Fixes 2 and 3 are right. Fix 1 is worth doing but, alone, fixes nothing that was measured: it needs the prose at the field too.** The rerun needs a wider scope than proposed.

| # | Fix | View |
|---|---|---|
| 1 | A repair line that says what to write | **Yes, with a fixed example. Not enough alone** |
| 2 | The timeout step always sets the limit, plus one prose line | **Yes.** One wording change |
| 3 | A real agent made to park in the lab | **Yes** |

## 1. Locations

**The better repair line doesn't touch the problem.** All 16 refused agents already repaired from today's line. What failed is the first try: every build, test and outside-review run spent it on the location. A repair line is read after that try is gone.

**So both, and the prose at the field is the one that counts.** The shared skill has the forms, and the agents don't apply them, because each field says "`at`: where you made it", which reads as words. The form belongs at the field:
- the builder's and tester's `decisions`: the line, as `path:N`;
- the tester's plan `behaviours`: a JSON array when there are several places;
- the reviewer's `noticed`: left out when the thing has no place in a file.

Dev Beta drafts, and the lines come to me.

**The repair line:** yes, it is cheap and it tells the agent what to write. Two corrections:
- **A fixed example, not one picked from the job's tree.** Picking a real file and line is new code for no gain: the agent already knows its files.
- **Where `at` may be left out, the line says so.** The outside review's slip was a thing with no file, and "write it as a file and line" would send it looking for one.

**If the rerun still shows the slip,** the next step is not more prose. It is the question I raised at the sign-off: whether a decision needs a checked location at all.

## 2. Long suites

**I agree with always setting the limit.** A shorter timeout from the agent buys nothing: at its end the command isn't stopped, it is parked, which is the case the framework least wants. The cost is a hung command holding a job for 45 minutes, which the owner has accepted.

**The prose line is needed as well.** The agent never sees the changed timeout, so it would still believe in a two-minute limit and skip the suite. I'd word it so that only length is ruled out as a reason:

> A check may take as long as it needs: run it, and don't skip it for its length.

A check that is refused, or can't run here, is still honestly `not_run`.

## 3. The parked stop with real agents

Right. With the limit forced to 30 seconds and a 60-second suite, the suite outlives it and the agent parks. That is the matrix's parked cell with a real agent. What I'll read in it: the refusal "write your report", then a report that claims no result the agent hadn't seen.

## 4. The rerun

Two scripts change: the repair lines and the timeout step. The plan's own rule for a script change is a new freeze and a full rerun. I'd hold to it where it is cheap and narrow it where it isn't:

- **F1 in full,** and **F2 in full with its control.** Both are automated. The repair-line text changes what the bad-location cells of every kind are scored on, and the timeout step runs on every Bash call.
- **F3, the named kinds only:** build, test and external-review, three each; add test-plan and test-plan-update, three each, since their slip is a location too and their prose changes; the parked builder and tester; the long-suite case for both a builder and a tester, since both get the new line.

**The bar for the location kinds:** the larger part accepted at the first stop, and none gave up.
