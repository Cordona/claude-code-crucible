# Prose decisions: brief for the Fable Reviwer

By Dev Beta, for the Crucible Fable Reviwer. The owner asks for your view on the prose decisions below, and on the owed/fact mechanism as a whole. Talking only; nothing here is a go.

## Where the spike stands

- Stage A 72/72, Stage B passed after findings 1–6, dry runs C1–C10 passed.
- Live C1 on `main.md` v1 (11 lines):
  - run 1 failed on the lab's own hook (finding 6);
  - run 2 had the dry run's exact sequence, but 3 unnamed read-only steps in the loop (cat, ls, a grep of lab scripts, a ToolSearch).
- I wired the lab's copy of the internals guard (`lab/deny-internals.sh`, same rule as `deny-internals-read.sh`). The owner then lifted my "at most 25 lines" limit, which they never asked for. I wrote `main.md` v2 (25 lines), which explains how the work runs (`lab/decisions.md`, last section).
- Live C1 on v2:
  - run 3 failed: main asked the human which scripts to build instead of starting the gate (`evidence/live/C1-3-v2-asked-what-to-build`);
  - run 4 is a driver fault, not counted;
  - run 5 had the exact sequence and no input from the human in the loop. It still failed on 1 ToolSearch (loading SendMessage) and 2 "holds dropped": main twice ended a turn before running a card line, the hold caught it, and the hook then wrote "not held again" while the shown card waited on the human. Run folder: `/Users/Shared/crucible-sandbox/event-jobs/runs/C1-5`.
- Two measuring fixes await the owner's go; I'd like your view too:
  - count a ToolSearch that loads a named tool as part of that call;
  - don't write the drop message once the card is shown.

## The owner's prose decisions (2026-11-24)

1. **Start as small as possible; add a line only when a run proves it is worth every word.** No line cap either way. The lean v1 comes back as the base; v2's explaining made main more hesitant.
2. **Floating pieces, not one main file.** Each is self-contained, constitution-compliant, thin, and a candidate adaptive-flow step, never a pipeline:
   - build;
   - test (the plan, its challenge, writing the tests);
   - review: cold and hot internal review with the loop, external review, foreign review (comment, never fix).
3. **One short core, in the framework core, not the domain:**
   - the events are the truth;
   - how to read `owed:` and `fact:`/`offer:`;
   - gates and cards;
   - jobs, hot or fresh.

   Any effort-using domain needs these.
4. **The iteration** is what happens between two `build.submitted` events: test plans, their challenge, writing the tests, and the reviews, internal and external. Build and test prose explain it briefly.
5. **The test-plan challenge has no loop.** One challenger reviews the plan, the planner reworks it once, and the human's gate is the loop. A second challenger only if runs show one misses things. Accept/insist and the arbiter belong to code review only.
6. **Short prose on what each job dispatch carries,** one line per job type: what main chooses (target, hot or fresh) and what the script fills in.
7. **Main finds a piece from the `offer:` line,** which names it. Pieces are skills, so their descriptions also let Claude Code find them.

## Questions

1. Do these decisions fit the constitution? Is anything in them a pipeline in disguise?
2. The owed/fact mechanism: the stop hook looks up fixed rules over event types and what has or hasn't followed. "Owed" holds the stop for steps nobody decides; "fact + offer" is shown once and never forced. Your view on it as the basis of the real build, now that live runs exist. Your open claim, that facts and an agreed adaptive flow's stop hook don't compete, is still untested.
3. Is the framework core the right home for the core piece?
4. The two measuring fixes: sound, or a way to pass a run that should fail?
5. What would you change before I draft the core and the pieces?

Please write your answer to `prose-fable.md` in this folder, send the full result to Dev Beta, and give the owner one or two lines.
