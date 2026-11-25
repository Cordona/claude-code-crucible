# Are the hook steps independent? Fable's review (2026-11-25)

By Crucible Fable Reviwer, for the owner. The owner's go is the only go.

**What I read, in full this time:** all 14 steps (8 under `agent-submission/hooks/subagent-stop/steps/`, 4 under its `pre-tool-use/steps/`, 2 under `crucible-events/hooks/pre-tool-use/steps/`), the three wrappers' calls to them, `recover-submission.sh`'s calls, the three `matchers.json` files, and the install check's rule for a registered step.

**Not done:** I ran nothing. Dev Beta's own calls of the steps are Dev Beta's evidence, not mine. Every statement below is from reading the code.

## Verdict

**Option A is implemented correctly, and every one of the 14 steps can be called alone.** No step reads a temp file, a variable or a reshaped input that only its wrapper makes. Each takes its input from its arguments or from the hook's JSON on stdin, and finds its neighbours from its own path.

There are three things a caller must bring, all small, and one of them isn't written down. I'd make four small fixes, and one change to the stop hook's wrapper, which is the only place where the rule "a thin wrapper" isn't met.

## 1. Step by step: what each needs from outside

| Step | Input | Needs from its caller | Called alone |
|---|---|---|---|
| `report-validation.sh` | `--effort`, `--job` file | nothing | works |
| `held-stop.sh` | `--effort`, `--job` file, `--lines` file | nothing. A stale job file gives a wrong try number, and the event's own rule refuses it | works |
| `report-stamp.sh` | `--effort`, `--job` file | **the stop lock held,** so two stamps can't take the same IDs. Its help says so | works; safe only when nothing else is stamping |
| `report-pin.sh` | `--report` | nothing | works |
| `working-commit.sh` | `--effort`, `--job` file | **the report already pinned.** Its help says so; it doesn't check | works |
| `submission-event.sh` | `--effort`, `--job` file, `--type`, `--sha256`, `--commit` | nothing | works |
| `fault-ended.sh`, `fault-stalled.sh` | `--effort`, `--job` file, `--step`, `--fault` | nothing | work |
| `deny-background-bash.sh`, `refuse-cd-git.sh`, `add-bash-timeout.sh` | the hook's JSON on stdin | that the call is a job agent's. Each help says so | work, for any Bash call they are given |
| `write-scope.sh` | the hook's JSON on stdin | nothing: it checks the tool, the type and the job itself | works |
| `deny-direct-event-write.sh`, `deny-internals-read.sh` | the hook's JSON on stdin | nothing: each checks its own tool | work |

**The `--job` file** is what `job-of.sh` prints. Anyone can make it with one call, so it isn't the wrapper's private state.

**The one thing not written down.** The stop hook's wrapper sets the session's id in the environment before it runs its steps, and the event writer stamps each event with it. A step that writes an event (`held-stop`, the two fault writers, `submission-event`), called alone without it, still writes a valid event, with that stamp empty. Nothing breaks. The four helps should name it under "Reads".

**The paths.** Each moved step counts five folders up from its own path to reach the skills folder, and three up to reach its component's lib. I checked all of them, and the event log's step that finds the framework's root, which now goes seven up. All are right for one level deeper.

## 2. "Only in the installed layout"

**Acceptable, and I'd not add it to 14 helps.** It isn't special to the steps: the wrappers and every other script that needs a neighbour work the same way. A step called from the source tree already refuses with "… isn't beside this skill … install first", which says what is wrong and what to do. One sentence in one place, where the installer's layout is described, is the right home.

## 3. What doesn't yet fit the owner's rule

### 3.1 The stop hook's wrapper isn't thin

The two tool wrappers are thin: pick the steps, run them, combine. The stop hook's wrapper does orchestration that must stay in it (the order, acceptance, the lock, the outcome on exit), and also one piece of real work: **finding the stopping agent's job across the efforts, with the second look for an agent that has none.**

That same search is written a second time in `write-scope.sh`. Two copies of one rule is the fault the constitution names.

**The change:** one script in `agent-jobs`, beside `job-of.sh`, that finds an agent's open job across the efforts. The stop wrapper and `write-scope.sh` both call it. The wrapper gets thinner, the copy goes, and the search becomes callable alone like the rest.

It isn't a fault in what runs today. I'd do it before step 4 and rerun the cells it touches: an accepted hand-in, the no-job case, and the write scope.

### 3.2 A step that does two things

`refuse-cd-git.sh` refuses two forms: `cd` before git, and a trailing `; echo $?`. Its name covers one. I'd rename it for what it is, the forms Claude Code refuses anyway, and not split it: a third form shouldn't cost another file and another process on every command.

`held-stop.sh` writes the refusal and, on the second, the job's end. I judge that one thing: the outcome of a refusal. Splitting it would move the counting into the wrapper.

### 3.3 Small fixes

1. **Three helps say what isn't true.** `report-stamp.sh`, `report-pin.sh` and `working-commit.sh` say "Run by submit-agent-work.sh". `recover-submission.sh` runs them too.
2. **The session id** in the "Reads" of the four event-writing steps, as in section 1.
3. **The rename** in 3.2.
4. **A proof per step.** The owner's point is that each step is callable alone. Make that a count a script gives: one runner case per step, called directly and not through its wrapper, in the installed layout. Dev Beta did this by hand for the tool steps and for one stop step; the other seven stop steps need an effort and a job file, which the runners already build.

## 4. What I checked and found right

- **No step is registered.** The three `matchers.json` files name only wrappers and lone scripts, and the install check reports a registered step as "extra".
- **No wrapper passes hidden state.** The tool wrappers hand each step the hook's JSON, with the command as the step before left it, in the same shape Claude Code gives.
- **No step calls another step.** Only wrappers and `recover-submission.sh` do.
