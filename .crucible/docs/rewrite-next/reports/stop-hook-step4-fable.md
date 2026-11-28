# Step 4, run 3, and the four proposals: Fable's review (2026-11-25)

By Crucible Fable Reviwer, for the owner. The owner's go is the only go.

**What I read:** the run-3 section of `evidence/stop-hook-real/README.md`, `parked.md`, the flagged lines and the build refusals in `counts.md`, the raw `job.refused` events of `test-fix-1` and `build-3`, the summary rule in `builder-common.jq`, the challenge rule in `test-plan-update-report.jq`, the shared `agent-report` skill, and the tester's prose on the mutation check.

**Not done:** I ran nothing and read no transcripts. Section 3 rests on one hook I know only from the probe logs, so it is a probe to run, not a design to build.

## Verdict

**The run did its job: it failed honestly, and it shows exactly why.** The mechanism held everywhere it was tested. What failed is one bug, and one design habit behind it: the framework asks a model to count characters, and ends a job when it miscounts.

| Proposal | My view |
|---|---|
| (a) The repair line gives the tightest limit | **Yes, and one step further:** a refusal must list everything wrong at once |
| (b) The limits in the shared skill | **Say the limits, but in each definition, and give the check a margin** |
| (c) Widen the `cd` step to more forms; a scratch folder for the tester | **No to both.** There is a better root for each |
| (d) Two tries or three | **Keep two for now,** and decide on the rerun's numbers |

## 1. What held

- **R3: 29 of 29.** Every refused job that was handed in was repaired by the agent alone, from the lines, with no word from main. This is the first proof of self-repair that wasn't scripted.
- **The planted facts** were met on every submitted job: real findings in the right file, fixes touching the code they name.
- **The write guard's speed is settled without any index:** 242 ms for one agent, 267 ms with six sessions at once. That is inside the bar I gave, so the proposal I advised against isn't needed.
- **The parked case didn't happen.** When Claude Code moved the slow command to the background, the agent kept working, read the finished output, and only then reported a pass. That is the honest behaviour I asked to see.

## 2. Lengths: the framework asks a model to count

**The numbers:** 0 of 33 accepted at the first stop. Nearly every flagged line is a length. And `build-3`, told to shorten two texts to 200, came back with 205 and 206, and the job ended.

**What that says:** a model aims near a limit and lands a few characters either side. Any exact length will be missed at the margin, whatever the prose says. An agent in the interactive run asked to run Python to count its own text. That is the framework's design pushing back.

**What a length limit is for:** texts a human can read on a card. A claim of 206 characters serves that as well as one of 200. Ending a build over six characters costs far more than the rule protects.

**So, three changes:**

1. **(a), and wider.** Fix the summary line to give its own limit. Then check the rule this broke: **one refusal lists everything that is wrong.** The bug is that the general text check ran first and hid the stricter one. Look for the same shape in the other rules.
2. **Prose states a target, and the check allows a margin.** The prose says 200. The check refuses only clearly too long, say above 250. A miscount then costs nothing, and a 500-character note is still refused.
3. **The summary is a commit subject, so let the commit step make it fit.** Every builder and tester run was refused on it, at 149 to 215 characters against 55. The limit exists so the subject line stays within 72. A script can do that without the agent: the subject takes the first words, and the full summary goes in the commit's body. The summary then follows the general text limit, and this whole class of refusal is gone. **Owner's call,** since it changes how working commits read.

**Where the prose goes.** Dev Beta proposes the shared skill. The text limit is enforced by each agent's own rules, and only two of three agents have a summary. By the owner's rule that agents share no report rules, this is one line in each of the three definitions, not in `agent-report`.

## 3. Locations and two prose gaps

These belong in the prose, and all are earned by three runs of three:

| Seen | Cause | Fix |
|---|---|---|
| `at` as `"a.sh:29,33"` or `"a.sh:3, a.sh:9-12"` | the skill says "or a list of them", read as a comma list in one string | say "a JSON array of them" and show one |
| `at` as `a.sh, the option loop` | the agent wants to name a part of a file | one line: a place you would describe in words goes by its line |
| `at: "description"` in the outside review | the thing noticed has no file | one line: something with no place in a file has no `at` |
| "C-N applied, but no new test" | the prose never says what "applied" means for a challenge that asks for a test | one clause on `answer` |

The first three do belong in `agent-report`: locations are checked by the plumbing, for every agent. Each line comes to me before it runs.

## 4. Proposal (c): commands

### 4.1 Not a longer list of forms

`cd <tree> && ls` was refused, but P19 showed `cd <tree> && make test` runs. So a `cd` chain is not always refused, and a hook that refuses them all would stop builders running the checks of real projects. This is the limit I set on that step, and the run now shows where the list ends: a variable prefix, a compound read, a temp folder. Each update of Claude Code can add one.

### 4.2 A probe for the root

Claude Code has a hook that fires **when it is about to ask**. The P16 probes logged it, headless too, with the command and Claude Code's own suggestion. If that hook can answer with a refusal whose reason reaches the agent, one step covers every form, with no list:

- a **compound** command from a job agent (a chain, a variable, a substitution) is refused with: run it as plain single commands, and your other commands still run;
- a **plain single** command is left alone, so it reaches the human as a real permission question, or the allow-list.

If the probe holds, the pattern step can be removed. If it doesn't, keep the step as it is and accept the rest as questions to the human in interactive use.

### 4.3 The tester's mutation check

**The prose causes this one.** It says: break the behaviour "in a copy, never in your tree … A break left in the tree would ship." The agent then needs a temp folder, which is refused.

The rule guards against something code already prevents: a test job that leaves a production file changed is refused at its stop, with "undo it". The matrix proved that.

**So:** no scratch folder. The prose says to make the break in the tree, run the test, and undo it. A break left behind can't be handed in. That line comes to me before it runs.

## 5. Proposal (d): two tries or three

**Keep two for now.** The count isn't what failed. Today the first try is spent on a length nearly every time, so a job really has one. After the changes above, most reports should pass first time, and two tries mean two again.

**Decide on the rerun.** If more than about a third of the runs still need a refusal, or any job ends on a second, different slip, go to three. A third try costs a few seconds. A job that gives up costs the human a decision and a tree to clean.

## 6. The rerun

**All 33, not a part.** The prose of all three definitions and of the shared skill changes, and every kind has flagged lines. Add the two parked cases and the full interactive set: only one of its three ran.

**The bar stays zero gave up.** Beside it, report the number accepted at the first stop. I'd call the prose healthy when that is the larger part.

## 7. Smaller

- **`gh auth token` in the interactive run** came from the Claude Code client at its start, not from an agent, and the stub refused it. The scorer should count only agents' calls.
- **Step 3's parked scenario** was never met by a real agent. It stays proven with the stand-in only, and the final bar should say so.
