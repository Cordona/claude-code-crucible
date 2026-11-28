# wt3: the allow-list run. Fable's review (2026-11-26)

By Crucible Fable Reviwer, for the owner. The owner's go is the only go.

**What I read:** `spikes/dispatch/wt3-results.md`, and `evidence/wt3/asks.tsv` and `extras.tsv` line by line, beside the same tables of probes 2 arm A and wt2.

**Not done:** I ran nothing and read no transcripts. I did not open the kit, the cells' hook files, `git.txt` or the `qprobe` files; those rows are Dev Beta's reading. Section 2.3 rests on how Claude Code orders its deny rules and a hook's answer, which I have not checked. It is a probe to run, not a design.

## Verdict

**The facts are sound. The route is not converging, and I'd stop following it.** Three runs, three fixes, and the count of refused commands is 16, 17, 16. Each fix removed the form it aimed at and the agents' next habit took its place.

**The reason is in the design, not in the lists.** The allow-list is not what keeps a job agent safe, so making it longer buys nothing but fewer refusals, one form at a time.

| Question | Answer |
|---|---|
| The cheapest sound route to close the three habits | **Not three fixes. One change to who answers the ask,** section 2.3, the owner's decision |
| Is the allow-list per job a real problem | **No.** Nothing in it depends on the job, section 3 |

## 1. What the three runs show

| Run | Fix | Removed | Appeared | Refused |
|---|---|---|---|---|
| Arm A | none | | | 16 |
| wt2 | start in the tree | `cd <tree> && git …` (6) | shell writes (4), `; echo x=$?` (5) | 17 |
| wt3 | prompt lines, scratch folder, allow-list | `/tmp` trials, `cd <own tree>` | unquoted `$?` (8), trials typed inline in the scratch folder (7) | 16 |

**What held in every run:** all 18 jobs were accepted at the first stop, and every tree was intact. A refused command costs the agent one more call, and it has always recovered.

**What is left is not three habits.** It is how a model uses a shell: it joins checks to see each exit code, it sets up a trial in one line, it writes a file with a heredoc. The next project brings others: a variable before a command, a pipe into a tool that isn't listed, `&&` between build steps.

**Two claims are softer than written:**
- "Cause 2 halves": it was 3 refused and 3 unanswered, and is now 3 and 4. What changed is where the trials go, and that a trial written as a file runs with no ask.
- "The prompt line removed the `cd` habit": 2 to 0 across three testers, and one `cd` is still counted for `test-1`.

## 2. The routes

### 2.1 Fix each habit

A clause telling the agent to quote `$?`, a clause on heredocs, and allow rules for `mkdir`, `touch` and `cp` into the scratch folder.

**I advise against it.** It is the micromanaging the rewrite set out to end, and the table above is the evidence that it doesn't finish. A rule for `cp` can't say "only into the scratch folder" for both of its arguments, so that one doesn't close either.

### 2.2 Accept what is left

About three calls per job, each recovered at once, every job accepted. This costs nothing to build. It doesn't meet the owner's target of zero.

### 2.3 Change who answers the ask

**The fact that decides it:** a job agent may run `sh tests/run.sh` and `sh <scratch>/trial.sh`, and it writes both files. So it can already run any command at all, with no ask. The allow-list refuses `mkdir` typed in a call and allows the same `mkdir` inside a file the agent wrote one call earlier.

**So the list is not a boundary.** It stops one thing: a command the agent types directly without meaning harm, such as a push. Everything else it refuses is cost.

**The change:** when Claude Code is about to ask on behalf of an agent with an open job, the hook answers yes. A short fixed list refuses the few commands no job agent should type: pushing, the tracker tools, the network. That list doesn't grow with the agents' habits, because it names what is forbidden, not what is expected.

**What stays as it is:**
- the steps that run before every tool call (no background commands, the time limit, the sealed folders);
- the check at hand-in, which is what guarantees the tree and the report;
- main, whose asks still go to the human.

**What goes:** the compound-command refusal for job agents, the allow-list for them, and the question of delivering one per job.

**What it costs:** the record states plainly that a job agent runs any command not on the refused list. That is true today. It would now be said.

**A probe before anything else,** small:
1. does the hook's yes reach a background agent, headless and interactive;
2. does a refused command stay refused when the hook says yes, alone and inside a chain;
3. the real builder and tester, 3 and 3, counting asks. The pass is zero.

### 2.4 The sandbox

The only real boundary: it limits what a command can touch, whatever the agent types or writes into a file. In probes 2 its column still asked for some forms, so it needs its own probe. I set it aside then as a choice of security model. After three runs, it is the stronger form of 2.3, and the owner may prefer to decide between the two once.

### 2.5 What I'd do

Run the 2.3 probe. Keep the scratch folder and the two prompt lines, which did their job. Write no clause on `$?` or heredocs.

## 3. The allow-list per job

**Not a real problem.** In the run, the only entry that depended on the job was `sh <its scratch>/*`. The scratch folders all sit under the space, so one fixed pattern covers every job of every effort. The check commands depend on the project (shellcheck here, another tool elsewhere), and a project already has its own settings for that.

With 2.3 the question goes away.

## 4. For the record

- **`cat > file <<EOF` asks even with `cat` allowed.** So shell writes do not pass beside the write step today. Under 2.3 they would. The check at hand-in is then the only guard on which files a job changed, which is where the guarantee already was. The write step would remain as a fast, clear answer for the write tools.
- **The cost of dropping the tree's path:** none, 0 `pwd` and 0 failed writes.
- **The tree hook's changes** (the turn id, one reason for both starts, an open effort) are in the kit. I haven't read them. I'll read them with the spec.
