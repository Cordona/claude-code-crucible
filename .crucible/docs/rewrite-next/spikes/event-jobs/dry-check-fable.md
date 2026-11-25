# Before the live runs: Fable's check (2026-11-23)

By Crucible Fable Reviwer, for the owner. Reading only; I ran nothing. Nothing here is a go.

**What I read:** `evidence/stage-b/findings.md`; `lab/c/main.md`, `lab/c/settings.json`, `lab/decisions.md`; `lab/main-stop.sh`, `lab/gate.sh`, `lab/scope.sh`, the first half of `lab/driver.sh`, the headers of the scripts main calls; the fixtures, driver logs, checks and expected sequences of C1, C2 and C10. I did not read C3 to C9, the script agent's report, or the Stage B raw evidence beyond B5.

## Verdict: go live, after three small things are settled

Nothing here is a reason to hold the live runs. Three things would make the first run break or pass for the wrong reason, and each is cheap to settle first.

1. **How a fact reaches main has never run with a model, and I doubt the channel.**
2. **`main.md` and the driver disagree on what follows a fact,** so the answer file goes out of step at the first one.
3. **The expected sequences pin a choice that `main.md` leaves to main** (hot or fresh), so a correct main can fail the comparison.

## 1. The three things

### 1.1 The fact channel

- `main-stop.sh` gives a fact as `additionalContext` on a Stop that is **not** held. Stage B never had a Stop hook on main (its `setup.sh` installs none), and the driver reads the hook's output itself, so nothing has shown that a model receives this.
- Even if the harness passes it on, the turn is already over: main cannot "offer it in one line" in a turn that has ended. The fact would sit unseen until the human types.
- That makes a false pass possible. The answer file's next line is "yes, review it". Sent with no offer on screen, those words are an instruction, and `gate.sh --help` lists `--fact`. Main could reach the review from the human's words alone, and the sequence would match.
- **To settle:** one short headless run that shows whether main speaks the fact. If it doesn't, hold the stop once with the fact line; `facts-shown` already limits it to once. That is one line said, not work forced, so it stays inside "a fact never forces the step".
- **A fail rule to add either way:** the tmux driver sends an answer only when a question or an offer is on screen, and a run where an answer went out with nothing asked fails.

### 1.2 What follows a fact

- `main.md` line 8: offer the fact in one line, and if the human wants it, run the `offer:` line. That line is `gate.sh --fact`, which prints a card and a gate. So the human is asked twice: once in main's words, once by the card.
- The driver does it differently: on the fact it runs the offer line at once, and the single answer "yes, review it" is the gate's answer.
- Live, the answer file is one line short at every fact, or main skips its own line 8. Either way the run stops matching.
- **The simpler rule:** the card is the offer. Line 8 becomes "a `fact:` line is a next step: run the `offer:` line under it". One question, and it is the pattern already agreed (a question after a card is a gate).

### 1.3 Hot or fresh in the expected sequence

- `main.md` line 6 leaves hot or fresh to main. The expected sequences record `delivery` on every dispatch, taken from a driver that always tries hot first.
- In C1 the driver first offers the review replacement to **the builder** (refused: own commit), then gives it to **a reviewer of the same round**. A real main will likely start a fresh reviewer there. That is a correct run that fails the comparison.
- I'd also call the driver's choice wrong for the real thing: a replacement given to a peer of the same round makes one agent hold two slots, and in round 2 the script then has to hand the first reviewer's own findings to a stranger. The "2 hot, 1 fresh" of C1 comes out right only by this accident; the spec meant the agent that ended badly isn't reused.
- **To settle, before the run and not after:** compare `delivery` only where the claim needs it (the fix goes hot to the builder; a loop round's reviewers, which `round.sh` derives). Leave it free on a gated dispatch and on a replacement, or have the script make a replacement fresh. An expectation edited after a red run is the false pass we set out to prevent.

## 2. Does `main.md` carry anything scenario-specific?

**No.** I read its 11 lines against all ten runs' answer files for C1, C2 and C10: no kind, no finding, no order of steps, no run's name. The step names in line 9 and the two script names in line 13 are the catalogue, not a scenario. Hash now: `0e936596881fedd5a328b869eefea6f8d9a5681e`.

What else main reads, and what to say about it in the results:

- **The held-stop lines are whole commands.** That is the claim itself (events tell main what is owed), so it is fair. Report it plainly: "thin prose" means 11 lines plus one line per owed step.
- **The review kinds come from the run's fixture** (`LAB_KINDS`), not from main. So the spike does not test main proposing a swarm. Say so in the results; it is a judgement the real flow gives to main and the human.
- **The cards carry `on yes:` lines with commands,** and main shows the card as printed. The human reads shell commands on a card. Fine for the lab; in the real thing the follow-up belongs where main sees it and the human doesn't.
- **A hold is dropped after two tries with nothing new.** Add a fail rule: a run with a "not held again" message fails, even if it finishes. Otherwise a main that ignores a hold twice passes quietly.

## 3. The expected sequences

| Run | Right? | Note |
|---|---|---|
| C1 | Yes, apart from 1.3 | Build, three cold reviewers, one gives up and is replaced, merge, choice, hot fix, round 2 by script, clean, end card. Seven holds. |
| C2 | Yes | No gate answer between `fix.chosen` and the last merge; the second fix follows the second merge with no gate; two loop rounds of a cap of three; round 3 is the one reviewer whose finding was left. The check that decides the claim is the "no gate between" one, and it is there. |
| C10 | Yes | The death is written in the second session; the same merge is owed after the second reopening; later dispatches are cold because the agents are gone. It fails honestly if a reopened session keeps its id. |

Two notes on C10:
- The plan has two reopening messages, the spec says one. Count both as the run's input.
- Check how the stand-in "hangs" live, since Stage B found the harness blocks a foreground `sleep`.

## 4. The Stage B findings

All five are true findings for the real build, and none blocks the live runs.

- **1 and 2 (lost assign, work before assign):** the waits are right for the lab. They mean a hook may sit for up to a minute, near a hook's own time limit. For the real design, look once at whether the agent's start can carry the job, before settling on waits.
- **3 (TaskStop):** a good find, and the hook on TaskStop is the right answer: a cancel needs no prose.
- **4 (permissions):** this was the run I asked not to skip, and it found what it should. Note that the live runs still bypass permissions for main, so main's own script calls are untested in a normal mode. The real build needs a grant for the framework's scripts too. One lab slip: a reviewer has no tree, so the read grant's pattern becomes `/*` and allows every path.
- **5 (the slow scan):** 98 seconds came from 500 open roots, which no real effort has. Before designing a summary or an index, time a realistic shape: 2,000 events on five roots, most closed. Skipping closed roots may be all it needs.

From the script agent's three:
- **`fix.chosen` isn't tied to a gate answer.** Same hole as the old `--gate` flag: main could start a loop, cap included, with no human answer. The sequence comparison catches it in the spike. In the real thing `choose.sh` must need the unused answer of that merge's gate.
- **Two rules for `gate.answered`:** the lab's way round it is fine, with one consequence to state: Stage A's approvals are a different type from the live ones, so only the C runs prove the real gate's answer as an approval.
- **Facts only as Stop context:** section 1.1.

## 5. Order I'd take

1. Settle 1.2 and 1.3 on paper; record `main.md`'s new hash if line 8 changes, and regenerate the expected sequences once.
2. The short run for 1.1.
3. C1. Stop at the first break, as the spec says.
