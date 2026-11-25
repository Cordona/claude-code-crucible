# Spike results: event-driven jobs (2026-11-24)

By Dev Beta, for the owner and the Crucible Fable Reviwer, who judges it against the evidence. Every run is listed as it was scored, and nothing is marked passed that didn't run. Corrected after Fable's check (`results-fable.md`).

- **Run folders:** `/Users/Shared/crucible-sandbox/event-jobs/runs/`.
- **Saved copies:** `evidence/`.
- **Each change and its reason:** `lab/decisions.md`.

## 1. Verdict

The lab is stopped (the owner and Fable, `enough-fable.md`). For the question it asked, the answer is yes. Events, the hooks and a few printed lines carry main through a review loop, with no flow written in prose and nobody typing inside the loop.

The method was flawed in three ways:
- **The harness kept changing after red runs:**
  - the driver changed seven times;
  - the scoring rules changed seven times, three of them set before the runs they scored (section 8).
- **The live check compared main against a script playing main,** so a good judgement call of main's own failed (C3-2).
- **Most red runs were the driver's, not main's.**

The result still stands, and can be read straight from the logs without any scoring rule. In C2-5, main made 31 shell calls, and each one was `next.sh`, a script `next.sh` or a card named, or a `--help`. It read no event file, card file or project file. On the same case, the first batch made 8 to 11 calls into the events folder. The design fixes (section 4) and the plain request changed that, not the scoring.

## 2. The spec's claims

| # | Claim (`spec.md` §1) | Status | Evidence |
|---|---|---|---|
| 1 | Every job emits its events (dispatched, assigned, then one submitted or ended) | **Rules, plus hooks with real agents** (cold, hot, good end, gave-up, TaskStop cancel). Live: C1, C2, C4-3. A death by closed session **not run live** (C10 never completed). | Stage A `evidence/stage-a-real-writer.out`; Stage B `evidence/stage-b/`, findings 1–6 |
| 2 | Every event traces to its job, round, root and agent | **Rules** (Stage A A1, A4). Live sequences per root matched in the runs listed in section 3. | `cases/`, `compare.json` per run |
| 3 | The scan: owed held with one line, facts shown, never held for waiting, roots never mix | **Rules** (A2, A8, A10). **Live:** holds fired 0 to 4 per run and none dropped after the fix. The held stop is a lightly used net, because main asks `next.sh` first. | `holds_fired` in each `compare.json` |
| 4 | The loop runs with nobody typing, from `fix.chosen` to the end card | **Shown live:** C1-12, C1-13, C2-4, C2-5, C2-6, C4-3 (one run, with a cancel), C5-3 (one run, with the human's stop), C3-2 (with the arbiter; failed only on delivery, section 3). | run folders |
| 5 | Main's prose stays thin and nothing else instructs main | **Shown for the lab's text:** `main.md` v5, 10 lines, plus the hold header (1 line), the printed lines, and 58 lines of `--help` across the nine main-facing scripts. The old rewrite's build, test, review and dispatch flows and seat-run references come to 708 lines. The comparison is rough: the lab covers less ground and has no real pieces. **Not shown:** finding a real piece from an offer line. | `evidence/main-md-v*.md` |

**Not run live:**
- C6 (two builds, a busy tree);
- C7, C8, C9 (test plan with its challenge, external review, foreign review): rules only;
- C10 (death and reopen): not completed;
- the flow test (facts beside an agreed adaptive flow);
- any run with agents that use judgement;
- any run in a normal permission mode (every run bypassed permissions).

## 3. Every live run, as scored

"First" is the score the run got when it was made. "Later rules" is a re-score under rules set afterwards, which is for comparison only and never the run's score. The text is the `main.md` version the run used.

For the first live batch (C1-12 to C3-1 and C4-1 to C10-1), the first scores were never saved to a file; they exist only in `batch-brief.md`. Each run's `compare-batch-score.json` was saved after the measuring fix (the card rewrite), and shows that score.

| Run | Text | First score | Later rules | Note |
|---|---|---|---|---|
| C1-0 trust, bypass, ask-pattern | v1 | not run | | driver: setup prompts and an ask pattern that matched an echoed command |
| C1-1 | v1 | fail | | the lab's hook refused interactive dispatch (finding 6) |
| C1-2 | v1 | fail: 3 unnamed | | sequence ok, loop unattended |
| C1-3 | v2 | fail: asked what to build | | an unclear request; main asked the human before starting |
| C1-4 | v2 | not run | | driver: a late trust prompt |
| C1-5 | v2 | fail: 1 ToolSearch, 2 holds dropped | | the drop message was the hook misreporting |
| C1-6, C1-7 | v1 + guard | fail: 4 and 5 unnamed | | broken `--help`; main ran `owes.sh` and built a round by hand |
| C1-8, C1-9 | v3 | fail: 6 and 7 unnamed; C1-9 read events 3 | | main reached `owes.sh` through a shell variable |
| C1-10, C1-11 | v4 | fail: 1 chain of two named scripts | pass | the first runs with `next.sh` |
| C1-12 | v5 | fail: typed in loop 1 (brief only); pass after the measuring fix | pass | the typed-in-loop result was a measuring fault (card rewrite) |
| C1-13 | v5 | fail: typed in loop 1, 2 unnamed (brief only); fail, 2 unnamed, after the measuring fix | pass | chains with separators; passes only under the later effect rule |
| C2-1 | v5 | fail: typed 1, 1 unnamed, events read 1 | fail: events read 1 | main read `review.merged` |
| C2-2 | v5 | fail: typed 1, 3 unnamed | pass | |
| C2-3 | v5 | fail: typed 1, 4 unnamed, events read 2 | fail: events read 2 | |
| C3-1 | v5 | fail: typed 1, 4 unnamed, events read 2 | fail: events read 2 | |
| C4-1, C5-1, C6-1 | v5 | fail | driver fault | requests typed into an open question |
| C10-1 | v5 | fail: sequence | | the driver stayed in step. It differed because the stand-in couldn't hang (so "died" became "gave up") and because the dry run expected cold after the reopen. Main re-showed the pending card from `next.sh` after each of two restarts. |
| C2-4 (first) | v5 | not run | | driver: the gate lookup missed `answers/` |
| **C2-4, C2-5, C2-6** | v5 | **pass, pass, pass** | | |
| **C3-2** | v5 | **fail: sequence** | | main's judgement, section 5 |
| C4-2, C5-2, C6-2, C10-2 | v5 | not run | | driver: a ticking timer kept main from looking idle |
| **C4-3** | v5 | **pass** | | cancel of a working reviewer |
| **C5-3** | v5 | **pass** | | the human's stop in a live loop |
| C10-3 | v5 | not run | | stopped when the lab ended |
| C6-3 | v5 | not run | | the lab ended first |

On the current text, the runs made against the expected sequence are:
- **Passed:** C2 ×3, C4-3, C5-3.
- **Clean apart from the sequence comparison:** C3-2.
- **C1:** C1-12 passes once the measuring fault is fixed; C1-13 passes only under the later effect rule.

## 4. What the lab taught (each with the run that showed it)

1. **A door beats hiding.** Hiding `owes.sh` didn't stop main working steps out itself: C1-8 and C1-9 reached it through a shell variable. One main-facing `next.sh`, printing what the held stop prints from the same code, did (C1-10, C1-11).
2. **Script outputs must answer what main would otherwise read.**
   - Main read `review.merged` because `merge.sh` printed only a seq (C2-1, C2-3, C3-1).
   - Main read `job.ended` before replacing a job (C1-13, C2-3, C4-1, C10-1, C6-1).
   - Main read the follow-up files before a choice (7 runs).
   - Fixed with merge totals, a `why:` line, and a choice line that says what it takes. No events were read inside a loop after that (C2-4 to C5-3).
   - **A fourth door is still missing:** to cancel the security reviewer in C4-3, main ran `cd effort/events && grep … job.dispatched.json`, then `cat 000008-job.dispatched.json`, then TaskStop. This was before the loop, so it wasn't counted. To cancel a job, main must be able to tell which running agent is which. So `next.sh`'s lines for running work should name the job, its kind and its agent.
3. **Cards carry no commands.** The human read shell lines on every card (C1-5). The follow-up now comes from the answer's event.
4. **The owed line carries its own instruction,** so standing prose shrinks (`main.md` v3 to v5).
5. **`--help` must work.** A broken `--help` sent main into the sources (C1-6, C1-7).
6. **Prose grows from the smallest.** This stands on the principle, and on ten lines carrying the loop. C1-3 doesn't prove it: the longer text, the new guard and an unclear request came at once, and main's question was about the request.
7. **Judge by what must always hold, not by a scripted order.** C3-2 shows a good call failing an order comparison.
8. **Mechanics found in Stage B (findings 1–6):**
   - a held lock loses an assign unless the lock wait is long;
   - an agent can work before its job is assigned;
   - TaskStop fires no SubagentStop;
   - a default permission mode blocks a background agent;
   - interactive sessions have no `run_in_background` field;
   - the scan is fast only when closed roots are skipped.
9. **A continued session still reaches its agents** (C10-1, one run).
10. **The internals guard is a fence, not a wall.** It resolves only `/`, `~` and `$HOME` paths, in the lab and in the real `deny-internals-read.sh`.

## 5. C3-2

Main gave the third fix to a fresh builder: "Because the earlier builder had already missed this finding twice, I gave it to a fresh one."

- The dry run's default was the same builder, and delivery was compared for fixes. Fable flagged the pinned delivery in `dry-check-fable.md` 1.3, and it was fixed only half way.
- The choice is sound and within main's judgement (hot or fresh is main's call). It failed only by the comparison, and is reported as such.

## 6. What the lab was not

- **One small task** (two shell files), with stand-in agents that follow a scripted act and answer in seconds. Long waits, and a human talking in between, are largely unseen; the wait was added only for C4, C5 and C10.
- **Stage A proves the rules given the events,** nothing about main. Its approval type (`gate.approved`) differs from the live one (`gate.answered`).
- **Every live run bypassed permissions.**
- **A screen-scraping scripted human.** It is the main source of the red runs, and is not carried into the build.
- **The scan's timing** was measured on a made-up shape of events.
- **The review kinds came from the fixture,** never from main.
- **Main wrote its own view of the code into the gate questions.** Whether it should is a question for the review piece.

## 7. Open risks, each with the check that settles it

| Risk | Check, in the build, before the step that depends on it |
|---|---|
| Facts and an agreed adaptive flow's stop hook compete | The flow test first, before any piece is written as a flow step. Its fail rule and fallback are said beforehand: one hook owns the stop, the other only reports. |
| A normal permission mode stalls an unattended loop | An early run with main and its agents in a normal mode, with the narrowed grants the real build needs |
| Real agents that think don't end their jobs properly | The first live validation with real agents on a real task |
| Test plan, external and foreign never ran with a model | The first live use of each, judged by the invariants |
| A death by closed session, and an owed merge after reopening | One real reopen during a working agent |
| A hung agent wakes nobody | A timeout fact (design work) |
| Main can't tell running agents apart to cancel one | `next.sh`'s lines for running work name the job, its kind and its agent; a cancel in the first live run |
| The held stop is a lightly tested net | The invariants checker reports holds per run |
| Finding a piece from an offer line | The review piece's first live run |

**The invariants to check on any run, the owner's real ones included:**
- no dispatch without the human's answer;
- no question between a fix choice and its loop's end;
- every round merged;
- a loop ends at or under its cap;
- every job ended or waiting.

The proposal is to carry them into the build as a script. The scripted human and the exact-sequence comparison stay behind in the lab.

## 8. Changes to the harness after red runs

Each is in `lab/decisions.md`, with its first scores kept above:
- **Driver:**
  - setup prompts;
  - the ask pattern;
  - a stall exit;
  - waiting for the real input box;
  - answering only the meant gate, and requesting only at an idle prompt;
  - the gate lookup in `answers/`;
  - idle ignoring a ticking timer.
- **Scoring** (seven changes; three were set before the runs they scored: event reads, the chain rule, holds reported):
  - the ToolSearch rule;
  - project reads reported;
  - event reads fail (set before its run);
  - the chain rule (set before C2);
  - holds reported, not failed (set before C2);
  - the loop window ending at the first `show-card`;
  - judging by effect (`c/effect.jq`).
- **Lab design, which are the findings of section 4:**
  - the internals guard;
  - `--help`;
  - `next.sh`;
  - cards without commands;
  - the three outputs;
  - the stand-in wait.
