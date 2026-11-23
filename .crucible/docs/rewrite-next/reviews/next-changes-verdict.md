# Next changes: Fable's answers (2026-11-23)

By Crucible Fable Reviwer, for the owner, on `next-changes-design.md`. This is a design review; nothing here is a go.

**In short:** item 1 confirmed with two small changes. Item 2 agreed, with another folder name. Item 3: one home each, yes, but I'd put two of the three somewhere else. Item 4: I overstated it; one small part of it is real. Item 5: sound if small, with one case to fix and a live run to decide if it is needed.

## 1. events-read fails closed: confirmed

This is the right fix, and I confirm it.

- **All or nothing: yes.** A reader that prints part of a log is worse than one that prints none, because every caller treats what it gets as the whole truth.
- **One exit code, not two.** No caller does anything different for "not valid JSON" and "can't be read": in both cases the log is damaged and a human must look. The line on stderr names the file and says which it is. Keep 5, which the help already promises, for both. One code less to explain in every caller.
- **`--paths` checking nothing: fine,** because it only lists.

Two additions:

1. **Show one caller meeting a damaged log, not only the reader.** The design says each caller already passes the reader's failure on. That is shown for the toolbelt. Core's own callers (the gate's answer reader, the effort's state, the flow's replay, the context, the grill, the spec approval) are where it matters most, and no run shows what they do. One case is enough to prove the pattern: `gate-answer.sh` on an effort with an unreadable event must refuse, never answer "no yes on record". The same for `effort-state.sh`, which must not report a state it couldn't read.
2. **Say what the hooks do.** The flow's Stop hook reads events too. A hook must never block the human over a damaged log, so it stays silent; say that in the design so nobody "fixes" it later.

## 2. Main's tools apart from the rest: agreed, with another name

The split is right and nothing in it is against the constitution. It removes more from main's context than any help trim: main lists one folder and reads only the helps it can use.

**The name: not `jobs/`.** The owner has given "job" a meaning: one task for one agent ("job replaces part"), and the dispatch design is written in that word. A folder called `jobs/` holding scripts that agents never run will be misread by main and by people. Use `scripts/internal/`. It says the one thing that matters: not called from outside the framework's own scripts.

Four smaller points:

1. **The skill's sentence should point only at main's folder.** "The scripts you run are in this skill's `scripts/main/` folder; each one's `--help` is its contract." Naming the other folder to forbid it only tells main it exists.
2. **Scripts that other components call** (`worktree-trees.sh`, `commits-merge.sh`, `open-work.sh`, `busy.sh`) go in `internal/` too: they are not main's. Where main and a neighbour both use a script (`identity-get.sh`), it lives in `main/`.
3. **The folder-against-help check belongs to the help checker, not the install check.** The install check's job is the install: links and hooks. Whether a help's first line matches its folder is a lint of the help text.
4. **Keep the first line "Run by <caller>".** With the folder as the truth it is no longer what protects main, but it still tells a human reader who calls the script.

Do it now. Every later piece (the sender, agent-run) adds callers, and each one makes the move dearer.

## 3. One home per shared rule

One home each: yes. On where:

**The repository rule: not in git-identity.** It is the bottom of the dependency chain, which is why it is tempting, but "which repository does this folder belong to" is not an identity question. Worktree, mount and commit would call the identity piece for something that has nothing to do with identity, and a later piece that needs the rule but not identities would have to take git-identity with it.

**The time-limit runner: not in core.** Core has no use for it; all its callers are in this domain. "Not domain-specific" is true, and it is exactly the reasoning the owner reverted once before as premature: abstract into core when a second domain needs it, not before.

**My recommendation for both: one small base component in the domain,** holding the repository rule and the time-limit runner as two scripts, with no skill of its own, the way `crucible-events` is core's base. Everything in the domain may depend on it; it depends on nothing. When a second domain needs the runner, it moves to core then. That is one new component instead of a rule in the wrong piece plus a utility in core.

The promise that the runner stops everything the command started is right, and it closes the known limit about a signer left waiting.

**Liveness: its home already exists.** `worktree-trees.sh` lists an effort's live trees today. A new `worktree-live.sh` would be a second script for the same question. Use the one that is there.

**Does moving the check from the rule to the script weaken an invariant? A little, and it is the right trade.**
- After the change, a rule checks shape, writer and used-once, and the script asks before it writes. A write that claims to come from the script would pass the rule for a tree that isn't live.
- That is the position we already took for `flow.agreed`, `spec.approved` and `identity.set`, for the same reason: what stops a direct write is core's guard on the writer, and a rule that re-derives another script's answer in a second implementation drifts.
- Apply it to all seven rules, the five in git-worktree included. Leaving the replay in those five keeps two implementations of liveness inside one component, which is the thing this item sets out to remove.
- Write it in the spec as a known limit, in the same sentence as for the identity.

## 4. Exits promised and not shown: I overstated it

I looked again. Stated plainly:

**As noise in the helps: not a problem. I withdraw that cut.** An exit line is the contract, it costs one line, and "6: the events lock stayed held: rerun" tells main exactly what to do in the one moment it needs it. I listed these lines beside the `--help | -h` usage line and the install facts as noise; they aren't of that kind.

**As missing proof, it splits in two:**

- **Exit 4, "git, a tool or a neighbour failed": not a problem.** It is the catch-all for something unexpected. Staging it per script means faking a broken tool, which proves little. The cases the runs already hold are enough.

- **Exit 6, "the events lock stayed held": a small real gap.** Every writer promises it, and the outputs show it for two scripts only, in git-mount and git-push. The lock itself works; what is unproven is that each write path passes the refusal on instead of swallowing it and reporting success. A swallowed 6 is a change made with no event, which is the failure the framework is built to prevent. It will stop being rare the day several agents write to one effort at once.
  **The fix is small:** one case per write path, not per script. Each component writes through one wrapper of its own, so that is about ten cases: the write refused under a held lock, the script's exit is 6, and nothing was left half done. The helps stay as they are.

One correction to my own method: the table behind that finding came from matching command lines in the outputs. It misses scripts run through pipes and hooks, so it over-counted what was missing. The two conclusions above rest on exact searches of the outputs, not on that table.

## 5. A hook that stops main reading the framework's internals

**Sound, if it stays small. One case in the design would hurt the owner directly, and I'd let a live run decide whether the hook is needed at all.**

**The real-path anchor: right.** Denying only what resolves into the framework's own tree is the one way to be sure a project with the same folder names is never caught, and the lookalike case in the evidence proves it.

**The case to fix before it is built: a session that works on the framework itself.** The owner develops Crucible in this repository, with the installed skills linking into it. As designed, every Read of a `scripts/lib/` or `scripts/internal/` file there would be denied, for Beta, for me, and for the owner's own sessions. The hook must stand aside when the session's working folder is inside the framework's own tree. The hook input carries the working folder, so this is one check. Add it to the evidence: the same read is allowed from inside the framework's repository and denied from a project.

**`events/*.jq`: yes, and `hooks/` too.** Nothing there is for main: a refused write already says what was wrong, and main has no reason to read a rule or a hook. Covering them costs nothing more and makes the rule one sentence: in a component, main reads `SKILL.md`, `flow-step.json` through the scan, and `scripts/main/`.

**Subagents: no probe needed.** The hook input already tells them apart: the gate's hooks pass a subagent's call untouched by its agent id. Whether to apply it to subagents is a choice, and I'd apply it to both: nothing in those folders is for an agent either.

**Keep the Bash half simple.** The one heavy script in core today is the guard that parses Bash command lines; I flagged it in the compliance audit. This hook should not become a second one. It catches a slip, so: look for the folder names in the command text, resolve only those paths, and accept the known limits as written. No parsing of `cd`, globs or quoting.

**Two things the design should say:**
- **A fault in the hook allows the call,** as with every other hook: a bug here must never block the human's work.
- **The deny reason should also say what to do when a script misbehaves:** tell the human, with the script's name and its message. Otherwise main, denied the source, has no next step but to guess.

**What it costs, plainly:**
- A process on every Read, Grep, Glob and Bash call, in every session, for a hygiene rule. The stake is context, not safety: reading an internal file harms nothing by itself, and what must never happen (a direct event write) already has its own guard.
- The human can't lift it by asking. If the owner tells main "look at that script and tell me why it failed", main is denied. The owner can open the file themselves; it is still a case where the human's word doesn't win.

**My recommendation on timing:** build item 2 first, then look at one live run before building this. With main's listing showing only `scripts/main/`, the slip this hook catches may no longer happen; in the six runs so far main read internals once, in run 4, while looking for how to record a gate, and the helps now answer that. If the run shows main still going into `internal/`, build the hook as above. If it doesn't, the hook is a cost with nothing to catch. The owner asked for it, so this is theirs to decide; the design's own proof plan already includes that live run.

## Ranked, as I now see it

1. events-read fails closed, with the core-caller case.
2. `scripts/main/` and `scripts/internal/`.
3. One base component in the domain for the repository rule and the runner; liveness from `worktree-trees.sh`, out of all seven rules.
4. One held-lock case per write path.
5. The read hook, after a live run with item 2 in place shows it is needed; with the stand-aside for sessions inside the framework's own tree.
