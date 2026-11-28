# Round 2 of the final verification: Fable's sign-off (2026-11-25)

By Crucible Fable Reviwer, for the owner. The owner's go is the only go.

**What I read:** `evidence/final2/` raw: `F1.txt`; the F2 README, both score files, and the events and hook calls of the S6 and S11 cells; for F3 the events of all 20 cells, every saved report's locations and gates, and the timeout hook calls of the long and parked cells. I recomputed the framework hash: it is the frozen `f71a0054…`.

**Not done:** I ran nothing and read no transcripts. I sampled F2 (S6, S11, the cell counts), not all 86 cells. The "moved to the background at 30 s" text is Dev Beta's reading; I saw only the timeout set to 30000 and the gaps between calls.

## Verdict

**Signed off. The three open items from round 1 are closed, one of them with an honest limit.** My counts from the raw files match Dev Beta's.

| Open item | Result |
|---|---|
| 3.1 Locations | **Closed.** 13 of 15 accepted at the first stop, 0 gave up, 0 location refusals |
| 3.2 The long suite skipped | **Closed.** Both agents ran the 150 s suite, the tester five times |
| 3.3 A real agent parking | **Not shown, and I'd stop trying.** Real agents wait; the refusal stays proven with stand-ins |

## 1. What I checked

- **F1:** every runner green, the hash the same at start and end.
- **F2:** 86 cells green, 86 red in the control. The S6 refusals carry the new line, and the challenge's `noticed` one also says `at` may be left out. In all three S11 cells the agent asked for 10000, the hook set 30000, and the refusal is the "write your report" line.
- **F3, the 15 runs:** 2 refusals in all, neither about a location, both repaired. Every location in every report is `path:N`, a range, or a real JSON array (the plan kinds use arrays in every run). The outside review left `at` out where the thing had no file, three runs of three.
- **F3, the long suite:** the hook set 2700000 on every call. The suite calls are about 165 s apart, so it really ran to its end. The agents asked for 600000 and 900000 themselves, not 120000: the prose line changed the belief, and the hook covers the rest.
- **F3, the forced limit:** the agents asked for 120000 and got 30000. Neither ended its turn. Trees are clean, and "pass" was reported after the run finished.

## 2. The parked case

**I accept it as it stands.** A real agent that is cut off waits for the result and reports what it saw. That is the behaviour the refusal exists to force. The refusal itself is proven in three matrix cells with stand-ins. The owner's page should say exactly that: proven with stand-ins, never needed by a real agent in 5 + 2 attempts.

## 3. The two smaller points

- **`typecheck` as `not_run`, "not applicable to sh".** I'd change nothing. It is one run, the report is honest and says why, and the builder in the same lab ran `sh -n` under that name. A gate list in the tester's prose would be a rule with one slip behind it. If it recurs, look again.
- **The tester cancelled 10 minutes after main's last turn.** This is print mode's own limit and the known dead-session case: no hook fires, the job stays open. It doesn't touch interactive use. It belongs on the list for the dispatch talk, beside "who ends a job nobody will finish".

## 4. For the dispatch talk, unchanged by this round

- **Compound commands still cost turns:** 36 refused in the 15 counted runs, most of them `cd <tree> && …`. Starting each agent in its tree would remove them.
- **`manual` is still `not_run`** where the agent may not run the changed script or make a temp folder. That is the allow-list per job.
- **The write hook:** 280 ms median in real runs, inside the bar. In the matrix under about 36 agents it is 920 ms, up from 725 in round 1. Not a blocker; the first place to look if real use ever feels slow.

## 5. For the owner's page

- Round 1's "99 compound commands refused" should read 64 in the counted runs, if it is still there.
- State the frozen hash `f71a0054…` and that round 2 replaces round 1 for the three open items only.
