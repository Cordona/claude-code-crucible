# Elevated review: verdict (2026-11-23)

By Crucible Fable Reviwer, for the owner. Scope and questions are in `elevated-review-brief.md`. I judged results and the constitution, not code; where I name a script it is for what it does, never for how.

## Verdict: aligned with changes

The pieces do what their specs promise, the evidence reproduces, and the constitution holds. Five changes follow; the first is urgent and is in core.

## What I did

- **Reran 14 of the 15 evidence runs** from `/` in my own scratch space. Each exits 0 and matches the stored output once ids, hashes, times and fresh scratch keys are ignored. Checks: git-commit 86 of 86, git-worktree 311 of 311, git-mount 161 of 161, git-push 85 of 85. Nothing was left running. I did not rerun `tracker-run.sh`: it reads GitHub and GitLab with the owner's own login.
- **Ran `--help` on all 87 scripts** and measured each against `help-rule.md`.
- **Compared every exit code a help promises with the exit codes the evidence outputs show.**
- **Tested one core script myself** in a scratch folder: `events-read.sh` on a broken and on an unreadable event file.

Not checked: the claim that a logging `sh` shim saw all 87 scripts run with real arguments. I found no record of that run to judge.

## Findings

### 1. The event reader drops events silently (core; evidence: my own test)

`events-read.sh`, given an event file it cannot read, prints only the events before it and exits 0. In my test, with event 2 of 3 unreadable, it returned event 1 alone: the unreadable one **and every later one** were dropped.

Everything that proves something reads through this script: whether a yes was already used, which gate answer is the newest, a flow's replay, which trees are live. A later "no" at a gate would not be seen. Constitution, value 3 (invariants in code, and they refuse) and value 4 (events are facts).

It is unlikely in practice (the writer makes events read-only for their owner), but the reader is the proof chain, so it must refuse. The fix is small. Beta found the first half of this; the loss of later events is new.

### 2. Evidence against the specs (question 1)

**Proven, success and refusal:** every piece in scope. The four toolbelt runs show each command, its output and its exit beside each check, so a reader can see what "PASS" stands on.

**Promises with no evidence**, from comparing helps with outputs:
- **Exit 6, "the events lock stayed held: rerun".** About twenty helps promise it. The outputs show it for git-mount and git-push only. For every other writer, core's included, it is promised and not shown.
- **Exit 4, "git, a tool or a neighbour failed".** About twenty-five toolbelt helps promise it. The outputs show it in three runs, for a handful of scripts.
- **`events-read.sh` exit 5, "an event file is not valid JSON".** True, I tested it, but no evidence run shows it, and it works only because `jq`'s own exit code passes through.

These are failures of the surroundings, hard to stage one script at a time. I would not ask for sixty new cases. One shared case per kind is enough: one writer refused by a held lock, one script with a tool missing. And the helps should not promise per script what was proven once.

**Designed, not built, and now recorded as such:** the sender refusing a tree that was not cut as a marked step; any answer to the "is this tree busy" scan.

### 3. The constitution (question 2)

Holds:
- **A domain-agnostic core.** Nothing under `framework/` names a git component, a worktree or the software domain. The gate's recorded choice and the step catalogue know nothing of what uses them.
- **Floating pieces.** Each component offers its steps in a file of its own, and no step file carries an order. Live run 6 showed main assembling, changing and closing a flow from them.
- **Events as facts.** No rule reads the gate's events. Each rule keeps to shape, writer and used-once, and leaves the human's yes to its script's question to the gate's reader.
- **Judgement with main and the human.** The skills are a few sentences each. They say what is main's to decide (which trees, when a tree takes in another's work, whether to remount) and what must never happen (a push retried with force, a commit in the human's checkout). No skill lists its scripts or their options.
- **One-way dependencies by path** in the domain: commit uses identity; worktree uses commit and identity; mount uses worktree and commit; push uses worktree.

Does not yet hold (value 11, one home):
- **"What a repository is"** is the same rule in three components, each calling it "the one rule".
- **Running a command under a time limit** is written twice and has already drifted: push stops what git started, commit does not. The spec's known limit about a signer left waiting comes from that.
- **"Is this tree live"** is replayed in seven event rules, two of them in components that don't own those events (`mount.made`, `push.made`).

### 4. The --help contract (question 3)

**Right for its audience, and consistent.** All 87 follow one template; all have `Exit:`, `Writes:` and `Stdout:`; none is wider than 80 characters; exit 2 means the same everywhere. An agent can call any script from its help alone, and a human can read it. Where a skill says "its `--help` says what the gate must record", the help still says it. This is a clear gain over what was there.

**The shape is not what the rule asks for.** The rule says about 8 to 15 lines. After the trim, 7 helps are at 15 or under and 80 are between 16 and 25, with fourteen sitting exactly at 25. Before it, 43 were at 15 or under. The total rose from 1,624 to 1,761 lines. The long ones were cut to a cap; the short ones grew to fill the template. Sufficiency won over brevity in every case.

**Three things are noisy in every help:**
1. **The second usage line, `sh NAME.sh --help | -h`.** 87 lines telling a reader, who has just run `--help`, that `--help` exists.
2. **`Needs: jq 1.6+`, `git 2.31+`, "core beside this skill".** 66 helps carry such a line. The rule itself says to name a tool only when a caller can act on it. These are install facts: checked once by the install check, not restated per script.
3. **Exits promised and never shown** (finding 2). A line a caller will never meet, in forty-odd helps.
Removing these three brings the total under the starting figure and most helps back toward the rule's size, with nothing a caller needs lost.

**One inconsistency that matters.** The core helps for recorded gates name the gate script's own options (`spec-approve.sh`, `flow-agree.sh`, `context-cut.sh`: "`show-card.sh --record … --accept LABEL --subject …`"). The domain helps say the same in neutral terms (`identity-set.sh`, `push-tree.sh`: "a recorded choice gate, record set-identity, subject …"). The compliance audit removed exactly the first form (fix F7): when the gate's options change, every help that quotes them goes stale. The domain form is the right one for all.

**The cost that trimming can't fix.** `git-worktree` has 20 scripts and 437 lines of help; 6 are marked "not for main to call", though about twice that many are jobs only other scripts run. The marker is the right idea, but main reads a help to find the marker. In every live run main listed the folder and read every help.

### 5. Fat files (question 4)

Size is a reason to look, not a finding. Ranked by where a second job still sits:

1. **`git-mount/mount-apply.sh`**: a dozen read-only checks that a mount can apply, then the apply, the record and the roll-back. The checks are their own job, and their result is what main needs for its card.
2. **`git-worktree/setup-plan.sh`**: finding candidates and deciding about them.
3. **`git-worktree/lib/git-worktree.sh`**: the largest library; it holds a rule (the repository) and calls to its own job scripts. It shrinks when the rule gets one home.
4. **`trackers/tracker-read.sh`**: two trackers, the link rule, comments and the cut in one file. Noted in the compliance audit; unchanged.
5. **Core's `hold-question-until-card-shown.sh`**: four steps in one hook, kept as one for a stated reason (hooks on one matcher run side by side). Leave it; it is the one justified exception.

`commit-tree.sh` and `commits-merge.sh` are long with one job each. Leave them.

### 6. The earlier toolbelt changes (question 5)

All three are still the right moves. Their order changes: the reader comes first, for the reason in finding 1.

## Ranked changes

1. **`events-read.sh` fails closed.** It refuses, naming the file, when any listed event can't be read or parsed, with its own exit code and one evidence case each. Core, so it needs the owner's go.
2. **Main's tools apart from internal jobs,** in every component: a folder main lists, and a folder it doesn't. This removes more from main's context than any help trim can.
3. **One home each** for the repository rule and the time-limit runner; liveness taken out of the two rules that belong to other components.
4. **Three cuts in every help:** the `--help | -h` usage line; `Needs:` lines that state install facts; exits that no evidence shows. Then the gate requirement written one way everywhere, in the domain's neutral form, and the rule's "8 to 15 lines" either met or changed to what the template really yields.
5. **Two shared evidence cases** for what is promised everywhere: a writer refused by a held lock, and a script with a needed tool missing.
6. **The remaining splits,** in the order of finding 5, for the separate effort.

## What this review does not show

How main behaves with the git toolbelt. No live run has used it: the sender and the agent-run piece are not built, and until they are, nothing calls most of these scripts but their own evidence runs.
