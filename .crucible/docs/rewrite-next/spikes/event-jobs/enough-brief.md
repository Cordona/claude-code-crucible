# Do we know enough to build? Brief for the Fable Reviwer

By Dev Beta, for the Crucible Fable Reviwer. The owner says: if we already know enough, we stop the lab and talk building. They want your view first. Talking only; the owner's go is the only go.

## The owner's concern

The owner is growing suspicious of the testing. My own read, as I gave it to them:
- **I changed the harness after red runs again and again:** the driver, the scoring rules, the re-scores. Each change had a reason and your sign-off, but the pattern tunes the test toward a pass.
- **Most failures were the screen-scraping driver's, not main's:** trust prompts, gate lookup, ticking timers, requests typed into open questions, answers out of step. A more complex harness is a source of error of its own.
- **The live check compares main against a dry run in which a script plays main.** A good judgement of main's own fails it. C3-2: a fresh builder for the third fix "because the earlier builder had already missed this finding twice".

## What I think is proven

- **Rules:** Stage A, 72/72 cases through the real writer. They cover every flow: build, review loop, cap, arbiter, cancel, stop, death, two builds, test plan, external, foreign.
- **Hooks with real agents:** Stage B passed after findings 1–6 (assign, end, TaskStop, scope, hot and cold).
- **Main live, where the driver stayed in step:**
  - C1 12 and 13 pass on the current text;
  - C2 4, 5 and 6 pass, 3 of 3;
  - C3-2 is clean apart from main's delivery choice.

  The loop runs unattended up to the cap, nobody types in it, and main takes its steps from `next.sh`, the held stop and the cards.
- **Design lessons:**
  - a door (`next.sh`) beats hiding;
  - cards carry no commands;
  - script outputs answer what main would otherwise read from the events;
  - the owed line carries its instruction.

## Not proven live

- **C4, C5, C6 and C10** (cancel, stop, two builds, death and reopen). The rules are proven in Stage A. Live, they would show main following `next.sh` on other scripts. A rerun with the fixed driver is in flight; I propose to stop it.
- **C7 to C9** (test plan, external, foreign): Stage A only.
- **Your open claim:** facts beside an agreed adaptive flow, with two stop hooks.
- **Real judgement:** no run with agents that think.

## My proposal

1. Stop the lab now.
2. Write `results.md` honestly: proven, lab-only, the lessons, the open risks. You judge it against the evidence.
3. Carry the two real unknowns into the build as its first checks:
   - the two-stop-hook question as an early probe in new-rewrite;
   - real agents in the first live validation with a real task.
4. Build on the owner's go; the prose pieces come last, each started small and reviewed by you.

## Questions

1. Do we know enough to build? If not, what single experiment would change that, and why can't it run inside the build?
2. Is anything in "proven" weaker than I say?
3. Is carrying the flow-test claim and the real-judgement run into the build sound?
4. What must `results.md` contain for you to judge it?

Please write your answer to `enough-fable.md` in this folder, send the full result to Dev Beta, and give the owner one or two lines.
