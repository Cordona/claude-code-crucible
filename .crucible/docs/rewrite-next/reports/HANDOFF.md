# Handoff: the agent reports and their submission (2026-11-24)

By Dev Beta, for itself after a compaction. Everything is uncommitted. Never commit or push unasked.

## Where we are

1. **The event-jobs spike is closed.**
   - `spikes/event-jobs/results.md`, judged by Fable, with the corrections applied.
   - Lessons:
     - give main a door (`next.sh`), not a hidden script;
     - script outputs must answer what main would otherwise read;
     - cards carry no commands;
     - grow prose from the smallest.
2. **The report schemas are agreed:** `reports/report-schemas.md` draft 3, plus `reports/decisions.md`.
   - Checked by the five PS Observer workers (`reports/worker-*.md`) and Fable (`reports/schemas-fable*.md`).
   - The timelines are in `reports/event-timeline.md`. Its `pr.*` names and Fable's five timeline corrections are not applied yet.
3. **The build agent's slice: built, proven, and approved by the owner.**
   - **Spec:** `reports/build-agent.md`.
   - **Tree:** `reports/build-agent-tree.md`. The owner removed the `submit-agent-work/` subfolder: the steps sit directly in `hooks/subagent-stop/`.
   - **Code in new-rewrite:**
     - `domains/software-development/core/main-thread/agent-jobs/`;
     - `domains/software-development/core/agents/agent-submission/`;
     - `domains/software-development/core/agents/code-builder/`;
     - changed: `framework/core/install/install-entries.sh` and `install-check.sh`, `framework/core/main-thread/crucible-events/scripts/internal/event-write.sh` (rules get `-L <components folder>`), and git-commit's `commit-tree.sh` (`--unsigned`) and `commit-message.sh` (help).
   - **Proof:**
     - `evidence/build-agent/run.sh`: 137 of 137, rechecked after the stop below;
     - live: `evidence/build-agent/live/`, 12 of 12 with a real sub-agent.
   - **Fable's verdicts:** `reports/build-agent-fable.md`, `build-agent-built-fable.md` and `tree-fable.md`.
4. **The test agent's slice: built, proven and live-validated.**
   - **Spec:** `reports/test-agent.md` (v3; §9 rewritten for the plumbing-only rule).
   - **Code:** `domains/software-development/core/agents/code-tester/`, kinds test-plan, test-plan-update, test and test-fix.
5. **The agents tree, version 3: agents share plumbing only** (`reports/agents-tree-proposal.md`; Fable: `agents-tree-fable.md`, `agents-tree-v2-fable.md`; design review: `agent-slices-design-fable.md`, applied).
   - **`agent-submission/`** is plumbing that reads no report's content. Its contract: a report is one JSON object, any `at` is a location, and a committing job's report has a `summary`.
   - **Each agent owns everything of its own:**
     - `submissions/<kind>.json`, which pairs the kind with its event;
     - `events/`;
     - `scripts/lib/<agent>-common.jq`, plus one `<kind>-report.jq` per kind.
   - No agent includes another agent's rules. Agents talk through events only.
   - **`fix` is split** into `build-fix` and `test-fix`, each with its own event and report folder. "Is this a fix" is a fact in the job (it carries findings), and the round counts per kind.
   - **The summary limit depends on the kind:** 55 for build and test, 51 for build-fix, 52 for test-fix, to keep the subject at 72 or fewer.
   - **The rule files were rewritten by hand** after an accidental delete (they were untracked). Both proofs pass on them.
6. **The reviewer's slice: built, proven and live-validated.**
   - **Spec:** `reports/review-agent.md` (final; §15 holds the decisions).
     - Workers: `worker-*-reviewer.md`.
     - Fable: `review-agent-fable.md`, `review-agent-final-fable.md`, and the design review of the code in `review-agent-built-fable.md` (pending).
   - **Code:** `agents/code-reviewer/`, with kinds review (cold, hot, re-review), test-plan-challenge, external-review and foreign-review. None of them commits.
   - **Plumbing added:**
     - the stamp step (`report-stamp.sh`), which runs an agent's own stamps;
     - the stop hook's own per-effort lock (`stop-lock.sh`), held from the stamp to the event, which keeps IDs unique between parallel reviewers.
   - **Words** (`decisions.md`):
     - a fix report lists `fixes`, each with a `status`;
     - a re-review lists `findings` plus `fixes` (fixed, open, agree, disagree);
     - an external review gives a `verdict` per point;
     - `outcome` is dropped;
     - finding IDs reset per iteration, and a foreign review numbers per job.
7. **Proof:**
   - builder: 158 of 158;
   - tester: 100 of 100;
   - reviewer: 92 of 92;
   - live with real sub-agents: builder 13, tester 14 and reviewer 18, all passing (`evidence/*/live/`).
8. **Left for the dispatch talk:**
   - `job.dispatched`'s list of the fields a job may carry;
   - the names of the dispatch scripts;
   - who creates `reports/<kind>/`;
   - an install-time check of the submissions files;
   - the plan-approval rule for a test job;
   - whether the reviewer keeps Bash: kept for now, since it needs git for the diff. If dispatch hands it the diff, drop Bash, and with it the tree check, which would then be a rule for nothing;
   - a review job must carry `base` and `head`;
   - one per-agent job check per agent, run by the dispatch before it writes the job;
   - **Plugins (`plugins-fable.md`):**
     - a role file (`build.md` or `review.md`) never travels without its plugin's `SKILL.md`;
     - the tester gets the testing standard's `SKILL.md` plus its language's `build.md`, for the gates. No tech `test.md` until an integration run shows a tester stumbling;
     - a language or framework is a lens too: each has a `review.md` with a Correctness section, giving IDs like `PHP-01`;
     - whether a review job carries the MR description, which self-documenting-code's duplication check needs;
     - a builder carries about 650 lines of plugins before its task: look at that at integration.
   - the untrusted-content, secrets, customer-data and held-stop lines: now the `agent-conduct` skill, loaded from each agent's frontmatter.
   - **Claude Code's own worktrees** (owner: "we need to talk about this definitely"). Claude Code can cut a worktree unasked: main passing `isolation: "worktree"` to an Agent call, or any agent running `git worktree add` itself (for example to read an unmerged PR branch); also background sessions, `-w`, EnterWorktree. Each would put a job outside the tree the framework manages. Options: the dispatch refuses `isolation` on a job agent; a `WorktreeCreate` hook that exits non-zero vetoes every Claude Code path (only inside a framework effort, so the owner's own `-w` still works); `worktree.bgIsolation: "none"`; a Bash PreToolUse guard on `git worktree add` outside our scripts.
   - **What a review covers:** the job names it (base..head: one build or test commit for a hot review, a range of unreviewed commits for a cold one); wider only when the job says so. Uncommitted work (the hooks-dashboard repo: unreviewed commits, pushed and not, plus uncommitted changes) can't be reviewed by a treeless reviewer until main snapshots it into a commit.
   - **Refuse a new job on a tree that isn't clean** (needed twice now): a dead session's open job, and S11, where a parked agent wakes after acceptance and may edit the tree with no job (`stop-hook-step3-fable.md`).
   - **One job, one tree, one repo** (the owner, 2026-11-25): an effort spanning repos gets a tree per repo, cut by main, and jobs per tree; a job agent writes only in its tree and its report (the write-scope hook). **Reading other repos:** P16 showed even reads outside the working folders ask, so the dispatch adds the repos a job may read as that job's extra working folders.
   - **How the job reaches the agent:** in words ("fix these findings"), so the prose needs no kind names, or naming the kind once in the opening. Fable (prose-v3-fable.md): the prompt must state the task in the definition's own words (the tester picks its report's shape by it); keep one task sentence per kind in the agent's own folder and let the dispatch only place it, so the dispatch never holds an agent's vocabulary.

## Next step (only on the owner's go)

1. Fable's design review of the reviewer's code; apply what the owner accepts.
2. **The review loop's spec:**
   - `review-round.opened`;
   - the merge and the round's result;
   - the review gate's lens choice;
   - the end card;
   - the answer to a routed notice;
   - the rules taken out until the loop exists: `reopens` naming a settled ID, and the key on `noticed[].for`.
3. The dispatch talk.
4. The landing step.
5. Prose, last.

## How the owner works (see memory too)

- **Small steps.** Talk and explain simply before doing; never jump ahead. Wait for the go.
- **Shapes first.** Every JSON shape is shown pretty-printed in an MD and approved before building.
- **Checks, in order:** the PS workers check fit first, Fable judges with their opinions, then the owner. Pure mechanics may go to Fable alone.
- **Reports stay generic:** free text or a gate before a new field.
- **Scripts:** separate scripts per step, called by a wrapper; hook-only scripts in the hook folder; shared ones in `scripts/`.
- **Folder conventions:** `<component>/hooks/<hook-type>/`, `events/<type>.jq`, `scripts/{main,internal,lib}`. jq that isn't an event rule goes in `lib`. Components are named for what they do.
- **Prove by running,** and show the outputs: report, event, commit.
- **Never:** `~/.claude`, real keys, kill by name, search from `/`, waits over 2 minutes.
