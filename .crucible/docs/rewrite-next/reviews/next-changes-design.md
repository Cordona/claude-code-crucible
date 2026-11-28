# Next changes: design for Fable

The owner agreed in principle to the first three, taken from the elevated review. The fourth goes back to Fable. Splitting scripts against the split / don't-split test is a separate effort later.

## 1. events-read fails closed (core)

**Today:** the first event file it can't read ends the read loop. Every later event is dropped, and the exit is 0 because jq's exit code wins. Reproduced: with event 2 of 3 unreadable, it returns event 1 alone.

**Change:**
- Before printing anything, it checks that every listed event can be read and parsed.
- If one can't, it prints nothing, names the first such file on stderr, and exits with a code of its own:
  - 5: not valid JSON (the exit the help already promises);
  - 7: can't be read.
- No partial list is ever printed.
- `--paths` lists only, so it checks nothing.
- Each callers already passes a non-zero exit from the reader on as exit 4, so callers need no change.
- One evidence case each, for exit 5 and exit 7, in `events-run.sh`.

**Question:** do the two codes and the all-or-nothing output stand, or should both cases share one code?

## 2. Main's tools apart from jobs (every component)

```
<component>/
  SKILL.md        "Your tools are in scripts/main/; scripts/jobs/ is never yours to call."
  flow-step.json
  events/*.jq
  scripts/
    main/         the scripts main calls; main lists this folder and reads these helps
    jobs/         run only by other scripts or by hooks, never invoked by an agent;
                  open-work.sh and busy.sh too
    lib/
```

- Later, when agent-run lands, `scripts/agents/` holds the scripts a subagent calls. Nothing has that role today.
- Core's scans for `open-work.sh` and `busy.sh` move to `scripts/jobs/` (one change in core).
- Hooks keep their own `hooks/` folder.
- The install check refuses a script in `main/` whose help says "not for main", and a script in `jobs/` whose help doesn't.
- The first line of a job's help stays "Run by <caller>; not for main to call."
- Every path changes: callers, the install entries, the evidence runs and the specs. No behaviour changes. All 15 evidence runs must pass again, with the shim's coverage record at 87 of 87.

**Question:** is `jobs/` right for a script only other scripts run, and is anything here against the constitution?

## 3. One home per shared rule (DRY)

- **What a repository is:** written four times (`gw_set_repo`, `gm_set_repo`, `gi_set_repo`, and `repo_git` in git-commit). It gets one home, in git-identity, the bottom of the domain's dependency chain. Each other component calls it by path, as with any neighbour skill, and never sources it.
- **Running a command under a time limit:** written in git-push and tracker-read, plus git-commit's own signing variant. It is not domain-specific, so its one home is core: a job script `run-timed.sh` with a `--seconds` option, an exit of its own for "timed out", and a promise to stop everything the command started. git-commit then also stops what it started, which closes the spec's known limit about a signer left waiting.
- **Is this tree live:** the replay moves into git-worktree as one job, `worktree-live.sh`. `mount.made` and `push.made` no longer replay worktree events themselves. Their scripts ask git-worktree before writing, so a rule only checks shape, writer and used-once.

**Question:** do the homes stand: the repository rule in git-identity, the time-limit runner in core, liveness in git-worktree? And does moving the liveness check from the rule to the script weaken an invariant (value 3)?

## 5. A hook that stops main reading the framework's internals (core; after item 2)

The owner asked for this. Purpose: catch main when, out of curiosity, it reads framework internals it should never need. It catches a slip, not an attack.

- **Its own hook, in core:** `crucible-...` under `hooks/pre-tool-use/`, beside `deny-direct-event-write.sh`. One hook, one job.
- **What it sees:** Read, Grep and Glob, through their path argument, and Bash, through the paths named in its command line.
- **Strictly the framework's own tree:**
  - The hook finds the framework root from its own resolved path; the installed skills are links into that tree.
  - It denies only when a target's resolved real path is inside that root, under a `scripts/internal/` or `scripts/lib/` folder.
  - A project with the same folder names never matches, because its real path is elsewhere.
- **Deny reason:** "internal to the framework; use this skill's `scripts/main/` and its `--help`".
- **Scripts run through `sh scripts/main/...` are unaffected:** the hook sees main's command line only, not what a script runs.
- **Known limits:**
  - A `cd` followed by a relative path, or a glob, can slip past.
  - Listing a parent folder still shows the names.
- **Subagents: to be probed.** Does the hook input tell a subagent's call from main's? The answer decides whether the hook applies to main only.
- **Proof:**
  - An evidence run feeds hook JSON for each tool: an internal path is denied, a `scripts/main/` path is allowed, a lookalike tree in a scratch project is allowed, and a link resolving into the framework is denied.
  - A live run in a sandbox session: main is asked to read an internal script and is denied, then reads a `main/` help normally.

- **Stand aside (owner, after Fable's answer):** the hook does nothing when the session's working folder is inside the git repository that holds the framework, not only inside the framework's own tree. Sessions working on Crucible start at the repository root, above the framework's folder. Because the installed skills are links into that repository, path alone can't tell "the repo" from "installed"; the session's working folder decides.
  - Inside the Crucible repo: main reads and edits anything (refactors, reviews).
  - In any other project: internals are denied.
- **Covered folders (Fable):** `scripts/internal/`, `scripts/lib/`, `hooks/` and `events/`.
- **Proof additions:**
  - the evidence run has a session at the repository root reading an internal script (allowed) and a session in a scratch project doing the same (denied);
  - the live run shows both.

**Question:** is the real-path anchor right, and should `events/*.jq` be covered too?

## 4. Exits promised and not shown: back to Fable

The owner doesn't yet see this as a problem. Please look at it again. If you still see a problem, state it plainly and propose the most fitting fix: shared evidence cases, a change to what the helps promise, or something else.
