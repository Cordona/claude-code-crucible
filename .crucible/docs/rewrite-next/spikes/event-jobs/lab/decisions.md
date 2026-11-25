# Lab decisions

## The approval is the gate's own answer event

**Decision:** the lab reads the core gate's `gate.answered`, written by its `record-gate-answer.sh` hook, directly as the approval of a gated step. No adapter writes a second event.

- **Step:** the gate's `record` (`build`, `test`, `test-plan`, `review`), given to `show-card.sh --record` by `gate.sh`.
- **Root:** derived from the gate's `subject`, which `gate.sh` writes as `<what>:<seq>` naming the event decided about (`no-review:4`, `test:9`). The view gives the answer that event's root; a subject with no seq (a first build) gives none, which matches any root, as before.
- **Yes or no:** a yes gate's `accepted` must not be false; a "no" approves nothing.
- **Main never names an approval:** `gate.sh` writes the card and prints the `show-card.sh` command; the human's answer is written by the gate's hook; the dispatch scripts find the unused answer themselves.

**Why not an adapter:** an adapter event would repeat what the gate's event already says, and would be a second writer of approvals. The shape allows the direct read once the subject carries the seq.

**What it costs:**
- The writer admits exactly one rule per type, and the gate's rule for `gate.answered` admits only its own hook and its six fields. The Stage A fixtures write their approvals through `ev.sh` with a step and a root, which the gate's rule refuses. `ev.sh` therefore stores the lab's own approval type as `gate.approved` (rule in `crucible-jobs`), and the view shows both as `gate.answered`. Only fixtures write `gate.approved`; a live run never does.
- The `<what>:<seq>` subject is a lab convention the gate does not know about.

## The stop hook's bound

`main-stop.sh` does not read `stop_hook_active`, because the core gate's stop hook doesn't either: that hook bounds itself by counting tries (two, then the stop goes through and the human is told). `main-stop.sh` does the same.
- A held line is held again only while the log has moved since it was last held.
- At one log position, an `owed:` line is held at most twice, and a gate line once. A gate waits on the human, and the gate's own stop hook takes over from the card.
- When a hold is dropped this way, the reason goes out as a `systemMessage`.

## main.md v2 and the internals guard

**Decision (the owner, 2026-11-24):** no line limit on `main.md`. The "at most 25 lines" in `plan-b-c.md` was mine, not the owner's. The prose main reads is still counted and reported beside the old flow skills, but the count decides nothing.

- `main.md` v2 explains how the work runs (events as the truth, the scripts name the steps, waiting needs no check) instead of only listing rules. v1's hash is kept in `evidence/main-md-v1.sha1`; v2's is in `evidence/main-md.sha1`. Live runs count from zero on v2; C1 runs 1 and 2 stay recorded as fails on v1.
- `deny-internals.sh` is the lab's stand-in for the framework's `deny-internals-read.sh`: the same rule and deny reason, mapped onto the lab's flat layout. Main may read and run the scripts it is given; the hooks, libraries, jq rules, agents and the real copies' internals are refused. It is wired for Read, Grep, Glob and Bash in `c/settings.json`.
- `compare.sh` is unchanged: a refused call still counts as an unnamed step.

## Back to v1, with Fable's recommendations (the owner accepts them all, 2026-11-24)

From `prose-fable.md`:
- **Baseline first:** `main.md` is back to v1 (hash `cc970a…`, the same as before). v2 is kept as `evidence/main-md-v2.md`. C1 runs twice on v1 + the internals guard + a plain request, which shows what the guard alone does to the stray reads.
- **The request is plain:** C1's first line is "build a.sh and b.sh in the repo". Run 3 failed partly on an unclear request. The re-run dry run gives the same `expected.json`.
- **Scoring, `compare.sh` (d):**
  - a ToolSearch that only loads a named tool, which main calls within 15 s, counts as that call;
  - reads of the project in the loop (Read, Grep, Glob, a read-only Bash line) are reported, not failed;
  - an unnamed write, dispatch or question still fails.
- **The drop message, `main-stop.sh`:** a gate whose card the core gate's record shows as shown is waiting on the human. It is neither held nor dropped. A dropped hold on an unshown card still fails (c).
- **Still to do, before any new prose:**
  - a shown card leaves the owed set (done in `main-stop.sh` above);
  - the card's `on yes:` lines move off the card into the gate's answer hook;
  - owed lines carry their own instruction;
  - the flow test;
  - then the review piece first.

## After the baseline (`baseline-fable.md`; Fable verified, the owner's go)

- **`--help` works:** `cli.sh` prints the script's header comment, its usage, on `--help`. Before this, every lab script answered "--effort is required", which sent main to `sed` the scripts. The scripts are executable, so `./gate.sh` runs.
- **Fix A in full:** main may run or read only what `main.md` or a printed line names: choose, gate, import, job-dispatch, loop-end, merge, remote, round, and the gate's `show-card.sh`. `owes.sh`, `view.sh`, `harvest.sh`, `busy.sh` and `orphans.sh` are internal.
- **Change 3:** the held stop's reason opens with "Owed now, decided already: run each line as given and make the calls it prints; do not ask the human." `main.md` loses the line that said it: v3, 10 lines, `evidence/main-md-v3.md`.
- **Scoring (e), set before the run:** main reading the effort's events (the folder or the view) inside a loop fails the run.
- **Left as is:** the classifier for chained named scripts. If a run fails only on such a chain, it is listed and said so.
- **For the real build:** the internals guard resolves only paths starting with `/`, `~` or `$HOME`, so a path in another shell variable gets through. It's a fence, not a wall.
- Dry runs C1–C10 pass and the Stage A cases 72/72 after the changes.

## A door to the next step (the owner's go, after C1 runs 8 and 9)

- **Runs 8 and 9:** the sequence was right and nobody typed in the loop. But main still built steps itself:
  - it reached `owes.sh` through a shell variable (`L=…; $L/owes.sh`), the guard's known gap;
  - run 9 read event files.

  Main wants to ask what is next; it doesn't end its turn to be told.
- **`next.sh`,** main-facing: it prints what the held stop would say, from the same code (`main-stop.sh --next`). That is the owed lines with their instruction, else each new fact with its offer, else what is still working. Nothing is counted as held, and a fact it shows is shown once, as from the stop.
- **`main.md` v4,** 11 lines: one added line names `next.sh` (`evidence/main-md-v4.md`).
- The internal scripts stay refused. The held stop stays as the net.

## Cards without commands (Fable's change 2), and rules set before C2

- **C1 runs 10 and 11 count as C1's two runs** (`baseline-fable.md` section 7): 2 of 2 with the expected sequence, each failing the script's check on one line that chains two named scripts. That stays their score (`score.txt` in each run folder). Their `compare-new-rules.json` is a re-score under the rule below, kept for comparison only.
- **Change 2:** a card shows the human only the decision. What follows each answer is kept beside it in `CARD.follow.json`. Once the gate's answer is an event and its follow-up's event is missing, the follow-up is owed:
  - `next.sh` and the held stop print it;
  - for a choice, the line reads `from the human's answer "<words>": <the choose.sh template>`;
  - the gate line of an answered subject is not held again.

  `main.md` v5, 10 lines, drops the `on yes:` line (`evidence/main-md-v5.md`). The dry driver takes the follow-up from `next.sh`, as main does. Dry runs C1–C10 pass with the same event counts, and Stage A is 72/72.
- **Rules set before C2:**
  - a Bash line whose every command is a named script counts as those named steps. Its parts split on `;`, `&&`, `||` and `|`. Plain `NAME=value` assignments are allowed; an `echo`, an internal script, `$(…)` or `eval` is not;
  - every held stop is reported with what it held (`holds_fired`), never failed;
  - only a dropped hold fails.
- **Live counting restarts on v5:** C1 ×2, C2 ×3, C10, C3–C6.

## After the batch (`batch-fable.md`; Fable verified, the owner accepts Fable's recommendations)

- **The measuring fix:** `gate.sh` writes a card only when it changes. A loop ends at main's first `show-card.sh` call for its end card. Unnamed steps and event reads are counted only inside a loop; over a whole run, main touched the events in every run.
- **Driver:** an answer goes only to the gate it is for (its card's record, from the dry run, against the core gate's shown record). A request or push goes only at an idle prompt with no question open. A request sent while a question was open fails the run as a driver fault, not run (f). In the batch, C4, C5, C6 and C10 had driver faults.
- **Three outputs instead of event reads:**
  - `merge.sh` prints the merge's totals (verdict, open findings by severity, to fix, slots with no report);
  - an owed replacement prints `why: <job name> ended its job: <reason>` under its line;
  - a choice's owed line says it takes those options and nothing else.

  The follow-up files moved out of `cards/` into `stops/follow/`.
- **Scoring by effect (`c/effect.jq`):**
  - fails: an unnamed write, dispatch or question, a lab-internal script, and any read of the effort's events, cards or stops folders;
  - reported: a read-only look at the project;
  - ignored: an echo of a literal or `$?`, a `cd`, a plain assignment.

  The batch runs keep their scores (`compare-batch-score.json`).
- **Plain requests:** C2 to C5 now start "build a.sh and b.sh in the repo".
- `main.md` is unchanged (v5), so C1 runs 12 and 13 still count.
- Dry runs C1–C10 pass, Stage A 72/72.
- **Not yet:** the stand-in that can wait, needed by C4, C5 and C10. Until it exists those runs are reported as not run.

## The live batch on C2 and C3, and the stand-in that waits

- **C2 runs 4, 5, 6: 3 of 3 pass.** C2 run 4 was first set aside as a driver fault (`runs/C2-4-lab-driver-gate-lookup`). While a question is open, the core gate keeps its record in `answers/`, not `owed/`, so the driver never saw the gate. It now reads both.
- **C3 run 2 fails on one point,** the delivery of the third fix. Main sent it to a fresh builder: "Because the earlier builder had already missed this finding twice, I gave it to a fresh one." The dry run's default was hot. The run is otherwise clean (0 unnamed, 0 events read). Left as a fail; it goes to Fable as main's judgement against the dry run's default.
- **A stand-in that waits:** an act's `wait: N` makes a stand-in run `perl -e 'select(undef,undef,undef,N)'` once. For a reviewing stand-in, `scope.sh` allows that exact command and no other shell. The dry driver ignores it. Used by:
  - C4 review 2 (90 s), so the human's cancel arrives while it works;
  - C5 review 2 (90 s), so "stop the loop" arrives in the live loop;
  - C10 review 2 (110 s), so closing the session finds it working.
- **C10's deliveries are free** (`sequence.jq`): `--continue` keeps the session id and still reaches the agents.
- **Idle ignores ticking timers:** while a background agent works, Claude Code shows a counting timer, so the screen never held still and the driver never saw main idle. Mid-work requests were never sent, and C4-2, C5-2, C10-2 and C6-2 stalled. They are set aside as `*-lab-idle-timer`. `idle()` now compares screens without digits.
- **C6's first build waits 60 s,** so "also build the installer in the same tree" arrives while it works, as in the dry run.
