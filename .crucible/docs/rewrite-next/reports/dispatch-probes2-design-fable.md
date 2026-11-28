# Probes 2, the wasted rounds and the attention line: Fable's review (2026-11-26)

By Crucible Fable Reviwer, for the owner. The owner's go is the only go.

**What I read:** `spikes/dispatch/probes2-design.md`, and from round 2 of the final verification the saved permission asks of the 15 counted runs and the session settings they ran with.

**Not done:** I ran nothing. Why Claude Code asks for each form below is my reading of the saved asks, not a fact I tested; the probe is what settles it.

## Verdict

**P-B is the right probe, with three additions. P-A as designed tests an idea the saved evidence already answers: the tree was a working folder in round 2, and the commands were refused anyway.** P-A should be redirected before it runs.

**A correction of my own number first.** I reported 36 refused compound commands in the 15 counted runs. The real count is **30**: 37 commands reached an ask, the hook refused 30, and 7 plain commands got no answer from it. My count matched a word that also appears in Claude Code's own suggestion. The owner's page and the probe design should say 30.

## 1. P-A: the wasted rounds

### 1.1 What the evidence already says

- **The space was in `additionalDirectories` in every round 2 run,** and each tree is inside the space. So "the tree is a working folder" was already true when the 30 refusals happened.
- **The 30 are three different things:**

| Form | Count | Example |
|---|---|---|
| `cd <tree> && git …` | 13 | `cd <tree> && git status && git log --oneline -3` |
| `cd <tree> &&` another chain | 12 | `cd <tree> && sh tests/run.sh; echo "t=$?"` |
| a chain with no `cd` | 5 | `d=$(mktemp -d); for i in …` |

- **The agents learn after one refusal.** 30 over 15 runs is two each: the first read of the tree, and the first check.

### 1.2 What I'd probe

1. **The cause, with one small command per form,** as the earlier permission probes did. A stand-in agent, the space as a working folder, the round 2 allow-list: `cd <tree> && ls`; `cd <tree> && git status`; `cd <tree> && sh tests/run.sh`; the same with `; echo "t=$?"`. Record which ask and what Claude Code says. I expect `cd` with `git` to ask whatever the folders are.
2. **Whether naming the tree itself changes anything,** against the space that holds it. One run. If not, the idea is closed.
3. **One line in the script-built prompt,** then the real builder and tester run: the agent is told where its tree is and that each command runs alone with the tree's path. The refusal already tells them this, one round too late, and they follow it. This has 30 real failures behind it, so it is prose the owner's rule allows. Count the asks before and after.

**The bar:** zero is the target; the result to report is the count by form, with and without the line. A habit like `; echo "t=$?"` may leave a few.

**What I'd not build:** a hook that rewrites the agent's commands, or one that answers "allow" by working out the allow rules itself. Both copy Claude Code's permission logic and break when it changes.

**Question 2, adding a folder mid-session:** not needed for this, since the space is added once at the start. It matters for the owner's read-only repos at dispatch. Record it, as a second priority.

**The 7 plain commands** (running the changed script, a temp folder) are the allow-list per job. They are not wasted rounds of this kind, and they stay for the talk.

## 2. P-B: the attention line

### 2.1 The shape

**"Not an event; a pushed line and a pulled view" is right.**
- What needs main is computed from events, so it is a view. Recording it as an event would make a second record of the same facts.
- **A line states a fact and nothing else:** "job 7 was dispatched and has no agent". That keeps main unconstrained, as the owner wants: no "start it or end it".
- **"Told once" kept in a small file by the script that reads it** is the right size. One writer, and losing it costs one repeated line.

### 2.2 Three additions

1. **Start from what main's Stop already runs.** Three hooks fire there today, one of which already ends the jobs of agents that are gone, and one of which already sends main back. Record what each tells main and the human now. The line should be one more step beside them, not a fourth mechanism, and two of them must not tell the same thing twice.
2. **Measure the script's time at a stop where nothing is new.** Main stops often, so this is the common case, and it must cost close to nothing. Read only this session's jobs: the assignment already names the session. A read of every effort on disk grows with the owner's history, which is the cost I flagged at the write guard.
3. **The interactive run is the real one for the wake.** Headless print mode handles background agents its own way, as the cancelled tester in round 2 showed. Do case (b), three reviewers finishing while main is idle, interactively as well.

### 2.3 On the three questions in the design

- **The forced turn.** A block at Stop is right only where main can act now and the slip is its own, such as a job dispatched and never started. Where main is waiting for the human's answer, a forced turn talks over the question. Record both, as planned; I expect the answer to be "ride the wake when an agent finishes, block only for main's own slip".
- **The wake.** This is the key fact of the probe. If a hook can add the line when main is woken by a finished agent, most items need no block at all.
- **All reviews in.** Main is woken by each reviewer as it finishes. Record what main does on the first eleven wakes when the line comes only on the twelfth.

## 3. The pulled view

Out of scope, and rightly. One thing for later: it should be the same computation as the pushed line, printed in full, so the two can't disagree.
