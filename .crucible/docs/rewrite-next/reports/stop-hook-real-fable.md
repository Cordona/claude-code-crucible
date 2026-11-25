# Step 4's trials and the three proposals: Fable's review (2026-11-25)

By Crucible Fable Reviwer, for the owner. The owner's go is the only go.

**What I read:** `evidence/stop-hook-real/README.md`, the allow-list and the launch lines in its `run.sh`, the commands the reviewer tried (from the saved hook calls of `trial-review-1`), and the three agent definitions' frontmatter plus `agent-conduct`.

**Not done:** I ran nothing, and I did not read the agents' transcripts. What I say about Claude Code's permission modes and about interactive sessions is from memory and is written as a probe to run, not as a fact.

## Verdict

**Stopping was right, and the four findings are real. I agree with the direction of all three proposals, and I'd change each one.** Two things are missing from the picture, and both come before the proposals:

1. **The trials ran headless, and the owner doesn't.** In a headless run every question Claude Code would ask becomes a denial. In the owner's interactive session a background agent's question may reach the human instead. Which one happens decides how serious findings 2 and 3 are, and nobody has probed it.
2. **The lab was kinder than real use.** Main was started inside the job's tree, with a wide allow-list that included writing to the Crucible space. In real use main sits in the repo, the tree is elsewhere, and no such allow-list exists. So a real agent needs `cd` or `git -C` even more often than the trial's did.

| Proposal | My view |
|---|---|
| (a) The reviewer gets `Write`, and a hook limits it to the report | **Yes to `Write`. The hook only if the chosen mode lets edits through** |
| (b) Probe the permission mode; the owner picks; install an allow-list for git | **Yes to the probe, with two more questions. No allow-list for git yet** |
| (c) One line in `agent-conduct` | **Yes, reworded, and without the report field** |

## 1. (a) The reviewer's report

**The finding is a design fault, not only a permission one.** The reviewer has no tool that writes a file, and its prose says "run no command that writes", yet it must write a report. The agent said so itself. It worked in earlier live runs only because Bash was let through.

**What I'd do, smallest first:**
1. **Give the reviewer `Write`.** Not `Edit`: a report can be rewritten whole, and `Edit` is the tool that tempts a reviewer to fix code. Add it later if step 4 shows repairs failing.
2. **The installer allows writes to the folder where reports live,** for every job agent. The lab had to add that rule by hand, so the builder and tester need it too. It is narrow, and it covers only Crucible's own space.
3. **The prose says what is true:** "write only your report" in place of "run no command that writes". That line comes to me before it runs.

**The hook, only if needed.** In `default` mode a `Write` anywhere else is a question, which a background agent gets as a denial. So Claude Code already does what the hook would do. The hook earns its place only if the owner picks a mode that accepts edits without asking. In that case I do want it, for a reason beyond tidiness: a reviewer can create a stray file with `Write` and has no way to delete it, so the stop hook's "undo your changes" could not be obeyed. If it is built, it lives in `code-reviewer`'s component, since the rule is the reviewer's own.

**The stop hook's tree check stays the backstop either way.**

## 2. (b) The permission mode

**Agree that the mode is the owner's call, and that it needs a probe first.** A definition that sets its own mode overrides how the human set up their session, so it must never be chosen quietly.

**Add two questions to the probe:**
1. **In an interactive session, does a background agent's question reach the human?** If yes, findings 2 and 3 are much milder in real use, but twelve reviewers each asking to approve a command is the micromanaging we set out to remove. If no, the headless result is the real one.
2. **Which plain command forms pass with no allow rule at all?** For example `git -C <tree> diff`, and `cd <tree> && sh tests/run.sh`. The trial's allow-list was wide, so it can't say.

**I'd not install a git allow-list yet.** An allow rule in the installer changes what every session on the owner's machine may run without asking, main included. Decide it after question 2, and only for the forms that turn out to need it. A project's own check commands stay the project's to allow, as proposed.

**What I'd aim for, whatever the mode:** the framework's own needs pass without a question (the report write, its own scripts), and everything else follows the human's permissions.

## 3. (c) The line in `agent-conduct`

**It is earned.** A real failure stands behind it: after one denial the builder reported every check as not run, though its test command was allowed.

**Two changes:**
- **No report field in shared prose.** `not_run` belongs to the builder's and tester's reports. The owner's rule is that agents share no report rules, and the reviewer has no such field.
- **Say it so it can't be misread.** "Denied alone" is terse.

**The wording I'd use:**

> A denied command says nothing about the next one. Try a plainer form (one command per call, `git -C <dir>` in place of `cd`) before you give up on it.

**How to know it works:** rerun the builder trial with only this line added. If the checks still come back unrun, the line is dropped, not lengthened.

## 4. Smaller

- **Finding 4** (a worktree is trusted through its main repo) goes on the dispatch talk's list, as Dev Beta says.
- **The builder trial's refusals** were a location written in words, a summary of 168 characters against a limit of 55, and a `noticed` text ten characters too long. It repaired all of them at once, which is the mechanism working. One run proves nothing about the prose; the counted runs will show whether the summary limit is refused every time.
- **The counted runs should start main in the repo, not in the tree,** so they measure the world the framework will run in.

## 5. The order I'd put to the owner

1. Run the probe in (b), with the two added questions.
2. The owner picks the mode.
3. Apply (a) as far as that mode needs, and (c).
4. Rerun the two trials. Start the counted runs only when the reviewer hands in a report and the builder runs its checks.
