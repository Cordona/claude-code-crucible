# A/B: agents in their tree, or in main's folder (auto mode)

2026-11-26. On the owner's go. No spec. Base: the split probe (`split-results.md`, `kit-split/`); kit `kit-ab/`; evidence `evidence/ab/`. Fable's verdict on the split run (`reports/dispatch-split-results-fable.md`) set the steps.

## Step 1: report words, old prompt against the new job message (reading)

Old built prompt (final2 F3, e.g. `evidence/final2/F3/logs/build-1/prompt.txt`): the task, then `Tree: <abs path>`, `Report: <abs path>`, then about 10 KB of plugins.
New job message (split, e.g. `evidence/split/arm/build-1/prompt.txt`): the task, then the tree line, the scratch line, `Report: <abs path>`.

**Lost report words: none.** The report line is the same in both, word for word (`Report: <path>`); the old prompt says nothing else about the report or the hand-in. What differs: the plugins moved out of the prompt into the start context, the report line is now the message's last line, and a scratch line was added. Every agent in both the earlier auto run and the split run called Claude Code's `SubagentHandback`; in the auto run they wrote the file first, in 6 split jobs they put the report into the handback instead. So the words didn't go missing; the agent's reading of a two-line ending did.

**Fix (in the door's message, script output, no definition clause):** the report line now says where and what, with the measured failure behind it:

- Before: `Report: <path>`
- After: `Report: write it to <path>, as one JSON object. That file is what is handed in; your final message is not.`

## Step 2: the 26 worktree-guard refusals against the earlier auto run (reading)

**Uncounted then, not new.** Counting the guard's two texts ("too complex to verify that it stays inside the worktree", "names git in a form too complex…") in the sub-agent transcripts:

| Run | Guard refusals |
|---|---|
| auto `arm` (allow-list) | 7 |
| auto `arm-n` (no allow-list) | 6 |
| auto `arm-i` (interactive) | 2 |
| split `arm` | 22 |
| split `arm-l` | 4 |
| split `arm-o` | 0 |

The earlier auto run had 15; its counter only matched "denied / not allowed / refused" texts, so the guard's lines weren't counted (they show in `evidence/auto/arm-n/_sessions/*/main.jsonl` too). The guard comes with worktree isolation, which both runs used; per job the rate is about the same (about 1.5 to 2). It is a cost of the tree start, not of the split.

## Step 3: the A/B run

Auto mode (`--permission-mode auto`), Opus main, real Opus code-builder and code-tester, 3 builds + 3 tests per arm, headless, one job agent per reply, the corrected job message, plugins in labelled parts at SubagentStart, the time limit in the settings env, the outward refusal step, and the start hook giving nothing to an agent already initialized for an earlier job. Frozen framework hash `f71a0054…` at setup and collect; nothing in `new-rewrite/` changed.

- **A:** isolation + WorktreeCreate, as in the split run.
- **B:** no isolation, no WorktreeCreate hook; the agent starts in main's folder; the note is taken and `job.assigned` written at SubagentStart (`take-note.sh`, under a lock, idempotent); the job message names the tree's absolute path: "Your tree: <path>. You start outside it: work only in your tree, never in the folder you start in."

| | A: in its tree | B: main's folder |
|---|---|---|
| Accepted at the first stop | **6 / 6** | **6 / 6** |
| Report put in the handback instead of the file | 0 | 0 |
| Permission asks / classifier denials / "no verdict" | 0 / 0 / 0 | 0 / 0 / 0 |
| Worktree-guard refusals | 8 | **0** |
| Claude Code's removal check (a command with `rm`) | 2 | 2 |
| Report write into a missing `reports/<kind>/` folder | 0 | 6 |
| Other failed command | 0 | 1 (`ls` of the missing folder) |
| **Wasted calls in all** | **10** | **9** |
| Writes landing in main's checkout | **0** (checkout diff empty) | **0** (checkout diff empty) |
| Trees clean on the job's commit | 6 / 6 | 6 / 6 |
| Three-event chain (assigned once, initialized once, handed in) | 6 / 6 | 6 / 6 |
| Tool calls by the agents | 68 (Bash 52, Write 8, Edit 1) | 54 (Bash 45, Write 3, Edit 0) |

Wall time is the same: a build about 1 minute, a test about 2.5.

**What the numbers say:**
1. **The report fix worked in both arms:** 12 of 12 at the first stop, 0 handbacks instead of the file (split run: 7 of 13, 6 handbacks). One sample per arm.
2. **The tree start brings the guard:** A's 8 are all the worktree guard (heredoc writes, `python3 - <<`, `sed -i`, scratch chains). B has none.
3. **B's waste is a different, fixable thing:** 6 of B's 9 are the report write `cat > <effort>/reports/<kind>/N.json` failing because the folder doesn't exist (the open "who creates reports/<kind>/" item); then `mkdir -p` or Write. A's agents mostly wrote the report with Write, which makes the folder. If the door made the folder, B's waste would be the 2 removal checks plus 1.
4. **No slip into main's checkout in B,** but nothing enforced it: B's agents changed code only through Bash (0 Edit, 3 Write, all for reports), each command that touched code started with `cd <its tree> && …`. The write-scope step covers Write and Edit only, so in B it never saw a code write. In A the guard bounds shell writes to the tree; in B only the agent's own `cd` did.
5. **The audit's cwd check flags B's three testers** ("worked in main's folder"): expected in B, where the start folder is main's; their files all landed in their trees.

## Kit (`kit-ab/`)

From `kit-split/real`, with: `ARM=A|B` in the runner (sandbox per arm, WorktreeCreate/Remove only in A, `SPIKE_ARM` in the settings env); cells limited to 3 builds + 3 tests; the job message's report line and B's tree line; the door printing the one-per-reply rule and isolation only in A; door-check needing isolation only in A; `take-note.sh` (B's assignment at SubagentStart); the start hook's resume rule; checkout snapshots before and after; the counter's guard, no-verdict and outward classes. Kit bugs: none hit in the runs. The kit's skill links are removed from the sandbox config; no process left.

## Evidence

`evidence/ab/arm-A`, `arm-B`: per cell events, reports, hooks, `git.txt`; `asks.tsv`, `denials.tsv`, `modes.tsv`; `checkout-before.txt`, `checkout-after.txt`, `checkout-diff.txt`. Raw sub-agent transcripts under `*/transcripts/` stay local.
