# The prose decisions and the owed/fact mechanism: Fable's view (2026-11-24)

By Crucible Fable Reviwer, for the owner, on `prose-brief.md`. Talking only; nothing here is a go.

**What I read:** the brief; `lab/c/main.md` v2; `lab/decisions.md`; Stage B finding 6 and the long-log result; the comparison files and screens of live runs C1-2, C1-3 and C1-5. I ran nothing. I did not read the run folders' events or hook logs.

## In short

1. **The decisions fit the constitution.** Two of them can hide a pipeline: the test piece, and the word "iteration". Both are easy to keep honest.
2. **Owed and fact is a sound basis for the real build.** The live runs show it: the exact sequence twice, and nobody typing in the loop. Its one real risk is growth: the owed rules are where a pipeline would come back.
3. **Core is the right home for most of the core piece, not all.** And most of it may not need standing prose at all.
4. **Both measuring fixes are sound,** each with one condition.
5. **Before drafting:** separate two things that changed together, fix the request in the fixture, run the flow test, and draft one piece first.

## 1. Do the decisions fit? Is anything a pipeline in disguise?

| Decision | Fits? | Note |
|---|---|---|
| 1. Start small, add a line only when a run proves it | Yes | It is "small, then learn". See 5.1: the evidence that v2 made main hesitant is one run, and two things changed at once. The decision stands on the principle, not on that run. |
| 2. Floating pieces | Yes | See below on the test piece and on review as one piece. |
| 3. One short core | Mostly | Section 3. |
| 4. The iteration | Unclear | See below. |
| 5. No loop on the plan challenge | Yes | The human's gate is the loop. It also removes the arbiter from one more place. |
| 6. One line per job type | Yes | Its home is `job-dispatch.sh --help`, not a separate text. Main already reads help when it needs it, and one home means the line can't drift from the script. |
| 7. Main finds a piece from the `offer:` line | Yes | This is the best of the seven: prose arrives when it is needed and not before. |

**The test piece.** Plan, challenge, rework, gate, write is a fixed order. It is not a pipeline in prose as long as the order lives in the owed rules and the piece only says what each job is and what main chooses. The test for the draft: delete every sentence that says what comes next. If the piece still reads whole, it is a how. If it falls apart, it was a flow.

**Review as one piece.** Internal with the loop, external, and foreign share the round and the merge and differ in how they end (a fix loop, replies, comments). Since main finds a piece from the offer line, splitting costs nothing: one piece for the round, merge, choice and loop, and two small ones that only the external and the foreign fact name. A main that never meets a pull request never reads them.

**The iteration.** Three questions before the word goes into prose:
- A fix also writes `build.submitted`. Does each fix round start a new iteration?
- With two builds in one effort, it is per chain, not per effort.
- What reads it? The model already has two keys, the root and the round. If a script needs the iteration, the script derives it and main never counts. If nothing reads it, it is a word for the human and needs one sentence, or none.

**Where a pipeline would really hide: the owed rules.** Section 2.

## 2. Owed and fact as the basis

**What the live runs show:**
- Runs 2 and 5 gave the dry run's exact sequence, on two different texts. So the sequence comes from the events and the hook, not from the wording. That is the owner's claim, shown.
- Nobody typed between the choice and the end card.
- Main ending a turn early and the hold catching it is the mechanism working, not a fault. Report holds per step; don't count them against a run.

**What I'd change in the design, from what the runs show:**

1. **A shown card is "waiting on the human", not "owed".** Today the gate step stays owed until the answer, so the stop hook holds it again and then gives up with a message. That is bookkeeping standing in for a state. Waiting on an agent never holds; waiting on the human at a shown card is the same thing. The scan should say so, from the gate's own record that the card was shown.
2. **The `on yes:` lines belong after the answer, not on the card.** The human read shell commands on every card in run 5. The gate's answer hook can hand main the line when the answer arrives. With floating pieces this matters more: it is the moment the next piece is named.
3. **An owed line can carry its own instruction.** "owed: run this as given" is said by the line itself, at the moment it applies. That is the smallest start decision 1 asks for: standing prose only for what no printed line can say.

**The risk to guard: owed is steering.** The constitution says code refuses and never steers. I accepted the held stop because an owed step is one nobody decides, inside a step the human approved. That test has to stay strict, because every new owed rule makes the chain a little more fixed:
- each owed rule names the approval that covers it;
- a new owed rule is reviewed like a new invariant, not added like a line of prose;
- anything a human or main could reasonably choose differently is a fact with an offer.

**Still open:**
- **Facts beside an agreed flow.** Untested, and decision 2 makes every piece a flow step, so it now sits under the whole plan. The claim to test: when the agreed flow already names the step a fact offers, main hears it once, from one hook. Run C1 with a flow agreed first, before the pieces are drafted as steps.
- **One rule file or one per component.** Still a claim.
- **A hung agent** wakes nobody. Known limit.

## 3. Is the framework core the right home?

- **Events as the truth, reading `owed:` and `fact:`, gates and cards: yes.** Their scripts are in core, and prose belongs beside the script it explains.
- **Jobs, hot or fresh: wherever the job scripts end up.** Decide the scripts' home first; the prose follows. The last attempt to lift things into core before a second domain needed them was reverted.
- **Don't restate the gate.** The gate component has its own prose. The core piece should point at nothing and repeat nothing; if it has four topics, it is four homes.
- With point 2.3, the core piece may come down to a few lines. That would be the result I'd hope for.

## 4. The two measuring fixes

Both are sound. Neither passes a run that should fail, under these conditions:

- **ToolSearch as part of the call:** only a search that selects, by name, the tool the printed call needs, followed by that call. Any other search stays an unnamed step. This is the harness loading a tool, not main deciding a step, and every real session will do it at its first hot send.
- **No drop message once the card is shown:** "shown" is read from the gate's own record, never from what main says. A dropped hold on a card that was not shown still fails. Better still is 2.1, which removes the message's cause.

One more, which the brief doesn't ask: **run 3's fail is partly the fixture's.** "Please write the two lab scripts" is unclear, and main asked what was meant before starting anything. Under "the human decides" that is good judgement, and a rule that fails it trains us to prefer a main that guesses. Make the request plain ("add a usage line to a.sh and b.sh").

And the "only named steps" rule: the guard now refuses reads of the lab's internals by code. A main that reads the project's own files before a build is using judgement. I'd fail a run on an unnamed write, dispatch or question in the loop, and report reads without failing on them.

## 5. What I'd change before drafting

1. **Separate the two changes.** v2 and the internals guard arrived together, so nothing shows which one removed the stray reads. The base is v1 anyway: run C1 twice on v1 with the guard and the plain request. That is the number every later line is measured against.
2. **Apply decision 1 to v1 too.** Its 11 lines were never proven one by one. No deletion hunt; just move into the printed lines what they can say themselves (2.3).
3. **Settle the three design points of section 2** (the shown card as waiting, `on yes:` after the answer, the instruction in the owed line) before prose is written around today's behaviour.
4. **Run the flow test** (section 2, still open).
5. **Draft one piece first, the review piece,** since it is the hardest. Run it. Then the others. Seven decisions drafted at once would be the big step the constitution warns against.
6. **Answer the three iteration questions.**

## 6. Follow-up: should the test-plan challenge be its own piece?

**No. Keep it inside the test piece, as one sentence at most.**

- **Main has nothing to choose in it.** Under decision 5 the challenge follows the plan automatically: one challenger, one rework, then the human's gate. It is an owed step inside a step the human already approved. Main's whole part is to run the line it is given, and the line says that itself.
- **A piece earns its own file when main can arrive at it on its own road.** External and foreign review each start from their own fact, and a main can need one without ever needing the others. Nothing starts a challenge except a plan.
- **The prose that matters for a challenge is the challenger's,** and that lives in the agent, not in a piece for main.
- **What the test piece keeps:** one sentence so main can tell the human what happens ("the plan is challenged once and reworked before you see it"). The card already says as much, so even that sentence should have to prove itself in a run.

**When it would become a piece:** if the human can ask for a challenge by itself, of any draft (a spec, a design, a plan). Then it is a reusable step with its own entry. Wait for that second use before lifting it out.

**The split that the same reasoning does point at:** the plan and the writing of tests are started by two different gates. If the human can ask for tests with no plan, those are two roads, and the test piece may be two small pieces. Worth one look when it is drafted.
