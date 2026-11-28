# Probes 2: results

2026-11-26, Claude Code 2.1.332, on the real install, frozen framework `f71a0054…` (hash checked at setup). Sandbox `/Users/Shared/crucible-sandbox/dispatch-probes2/`. Design: `probes2-design.md`, with its "After Fable" section. Nothing in `new-rewrite/` changed; nothing committed.

## P-A: refused compound commands

### 1. The cause, one command per form

A stand-in sub-agent ran 8 commands on a tree inside the space, one per call, in permission mode default with the round 2 allow-list (`evidence/probes2/P-A/form-probe/`).

| Command | Space as working folder (pa1) | Tree named too (pa2) | + `git status*`, `echo *` allowed (pa3) | Bash sandbox, auto-allow (pa4) |
|---|---|---|---|---|
| `cd T && ls` | ran | ran | ran | ran |
| `cd T && git status` | **asked**, no rule offered | **asked** | **asked** | ran |
| `cd T && sh tests/run.sh` | ran | ran | ran | ran |
| `cd T && ls; echo "t=$?"` | **asked**, offers `echo "t=$?"` | **asked** | ran | **asked** |
| `cd T && git status; echo "t=$?"` | **asked** | **asked** | **asked** | **asked** |
| `cd T && sh tests/run.sh; echo "t=$?"` | **asked** | **asked** | ran | **asked** |
| `git -C T status` | ran | ran | ran | ran |
| `ls T` | ran | ran | ran | ran |

- **`cd` itself is not the cause.** `cd` into a working folder followed by an allowed command runs.
- **`cd` followed by `git` always asks.** That held whatever the folders and with `git status` allowed, and Claude Code offers no rule for it. Only Claude Code's Bash sandbox let it through.
- **The `; echo "t=$?"` part asks** until `echo` is allowed.
- **Naming the tree itself as a working folder changes nothing.** That idea is closed.

### 2 and 3. The real builder and tester

Each arm ran 3 builds and 3 tests, with Opus agents and an Opus main, headless, in permission mode default with the round 2 allow-list. All 18 runs were accepted at the first stop.
- **The line:** added to the built prompt after Tree and Report: "You run from another folder, not in your tree: give each command the tree's path (git -C T ..., sh T/tests/run.sh), one command per call."
- **The wider allow-list (arm C):** git status/log/diff/show, echo, ls, find, cat, head, mktemp and `command -v`, all without -C.

| Form | A: no line | B: the line | C: the line + a wider allow-list |
|---|---|---|---|
| `cd T && git …` (refused) | 6 | 3 | 4 |
| `cd T &&` another chain (refused) | 4 | 2 | 1 |
| a chain with no `cd` (refused) | 6 | 2 | 4 |
| **refused by the hook** | **16** | **7** | **9** |
| plain command, no answer (headless deny) | 5 + 1 chain | 6 | 5 + 1 chain |
| asks in total | 22 | 13 | 15 |

- **The line roughly halves the refusals but doesn't reach zero.** The wider allow-list adds nothing.
- **What's left:**
  - `cd T && git …` as the agent's first look around;
  - chains the agent builds by hand to try its changed script (`d=$(mktemp -d); for …; sh T/bin/…`);
  - each chain arrives in one call.
- **The unanswered plain commands are the per-job allow-list matter:** `sh T/bin/prune-backups.sh --help`, `mktemp -d`, `command -v shellcheck`, `cp`.
- **Adding a folder mid-session was not tried** (second priority).
- **Per-ask lists:** `evidence/probes2/P-A/run*/asks.tsv`, made by `kit-pa/count.sh`.

**For the talk:** zero isn't reached by prompt or allow-list. Two routes the evidence points to:
1. **Claude Code's Bash sandbox:** it removed the `cd` + `git` ask, but not the echo forms. This is a security model choice.
2. **A way for the agent to try its changed script** without building a chain by hand, which is the manual check.

## P-B: the attention line

### Main's Stop hooks today

These are the installed hooks (`evidence/probes2/P-B/stop-hooks.json`):
- **`end-gone-jobs`:** writes `job.ended` no-stop for an agent that's gone. It tells only the human, by `systemMessage`, and only when it can't record that.
- **`remind-flow-position`:** sends `additionalContext` to main, once per signal, about its open flows.
- **`require-card-shown`:** sends `additionalContext` while a card is owed. Its help says main continues only when it prints that.
- **The SubagentStop hook** tells the human "job N … gave up" by `systemMessage`. Nothing tells main.
- **So the line repeats nothing:** it is main's only notice of gave-up, fault, stalled, gone, never-started and all-in. One caveat: a `job.ended` that `end-gone-jobs` writes at a stop is seen by the line only at the next wake or stop, because the Stop hooks run together.

### Which hook carries the line

| Case | What happened |
|---|---|
| (a) a job gave up while main waited, headless | The agent's end woke main, and **UserPromptSubmit fired on that wake**. Its `additionalContext` carried "Job 3 (echo) ended without its report: gave-up (event 7)", and main's reply used it. No block needed. |
| (b) 3 reviewers finished while main was idle, headless | UserPromptSubmit fired on each of the 3 wakes. "All 3 reviews … are in" was spoken once, at a Stop, because all three handed in before main's turn ended. Main on the earlier wakes: "Job 3 finished… next I'd wait for Jobs 4 and 5". |
| (b) interactive (tmux) | Same: UserPromptSubmit on each wake. You see the line as "Stop hook says: All 3 reviews on tree t1 are in", and main took one more turn after it. |
| (c) dispatched, never started, `additionalContext` at Stop | Main took **one more turn**, two stops for one task. It said the job was left unstarted on purpose. |
| (c) the same, as a Stop block | Also one more turn, and the same reply. |
| (c) block while main waits on the human, interactive | Main re-asked its question after the block. You see "Stop hook reported a problem" plus the line; main didn't start the job. |

- **Any Stop output costs main one extra turn,** whether it's `additionalContext` or a block.
- **UserPromptSubmit on a wake costs nothing,** because main is taking that turn anyway, in print mode and interactively.
- **So:**
  - failures and all-in go on UserPromptSubmit;
  - only never-started needs Stop, because there is no wake. That's main's own slip, so plain `additionalContext` is enough and a block adds nothing.

### Told once, and cost

- **Told once:** each line was spoken once in all 6 cases. No key appears twice in any told file, including b's 4 stops and 4 wakes.
- **Time with nothing new:** mean 91 ms at Stop and 73 ms at UserPromptSubmit, with 4 efforts on disk. With 54 efforts on disk and 1 of them this session's: about 250 ms, because each effort costs one grep. An index from session to efforts would remove that.
- **Only this session's jobs are read:** `job.dispatched` whose `claude_session_id` is this session.

## Kit bugs fixed

- My first timing run pointed at the wrong space folder (40 ms for nothing). I reran it against the real space.
- The F3 setup also made the long and parked cells; their sessions were removed before the runs, so their evidence folders are empty.

## Seen on the way (out of scope)

- **Claude Code blocks a lone `sleep 60`** ("use Monitor"), and the agent-tools hook refuses it in the background. So a SLOW stand-in can't wait by sleeping.
- **In this sandbox config, stand-ins reported a block of "MCP Server Instructions"** (a claude.ai docs connector) in their tool results, and ignored it.
- **Interactive mode runs Claude Code's own side agents,** and each fires SubagentStop. In cq there were 2 SubagentStops with no job agent started.

## Design changes

1. **P-A: the prompt line is worth keeping, but it isn't a fix.**
   - `cd` + `git` is Claude Code's own ask; the agents' remedy for it is `git -C`.
   - Hand-built test chains are the rest. Zero needs a decision at the talk: the Bash sandbox, or a way to run the manual check.
2. **P-B: the line goes on UserPromptSubmit.** Stop carries only never-started, as `additionalContext`, never a block.
3. **"All reviews in" is decided when the line runs, not by the last wake.** It may be told one wake early, which is harmless.

## Evidence

- `evidence/probes2/P-A/`: the form probe, the three arms with `asks.tsv`, and their hooks and events.
- `evidence/probes2/P-B/`: per case, the hooks, `main.jsonl`, the prompt, `events.json`, the told file, and the interactive screens.
- `evidence/probes2/P-A/*/*/transcripts/` are raw sub-agent transcripts: keep them local, never commit them.
- Kits: `kit-pa/` (F3 copy plus the line flag and `count.sh`) and `kit-pb/` (dispatch kit plus `attention/attention.sh`).
