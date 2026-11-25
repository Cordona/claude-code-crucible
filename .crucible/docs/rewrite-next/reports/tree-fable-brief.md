# The build agent's tree: brief for the Fable Reviwer

By Dev Beta, at the owner's request. Please propose the tree that makes the most sense for building `build-agent.md`, consistent with new-rewrite. Talking only; the owner's go is the only go.

## What has to live somewhere

- **The job events:** the `job.dispatched` rule plus a minimal writer (the tests need real jobs; the full dispatch comes next), and the `job.ended` rule. They are generic, not software-development-specific.
- **The shared pieces:** one function that counts the iteration and fix round, and the check that joins an event to its pinned report.
- **The stop hook for sub-agents,** shared by every agent kind:
  - a wrapper, plus one script per step: validation (calls the stopping agent's own checker), pin, working commit, event, held-stop count;
  - one shared script: recovering a missing event from a commit's `Job` trailer.
- **The build agent's own pieces:** its report validation (a script plus its jq rules), and the rules for `build.submitted` and `fix.submitted`. Later, its prose.
- Reused, unchanged: `git-commit`.

## The owner's rules so far

- Every hook sits at `<component>/hooks/<hook-type>/<what-it-does>.sh`, as all hooks in new-rewrite do.
- Scripts used only by one hook sit in that hook's folder; only shared scripts sit in `scripts/` (`main`, `internal`, `lib`).
- An event type's rule lives with the component that owns the type (the builder's events with the builder).
- The SubagentStop hook isn't a main-thread hook. The owner suggested `agents/common/hooks` and `agents/common/scripts` for the shared agent pieces.

## What I found in new-rewrite that constrains it

- **Only `main-thread/` folders are scanned.** `framework/core/install/install-entries.sh` installs as components only folders directly in a `main-thread/` folder, each linked as `~/.claude/skills/<bare folder name>`.
- **`agents/` would be invisible.** Nothing under it would be installed, and the event writer (`crucible-events/scripts/internal/event-write.sh`) finds a type's rule only among installed components beside crucible-events.
- **A bare folder name is the installed name.** `agents/common/` would install as the skill `common`: meaningless once installed, and it clashes the day another domain has one.
- **Only three hook folders are mapped:** `stop`, `pre-tool-use`, `post-tool-use`. A `subagent-stop/` folder isn't mapped.
- Every jq file that isn't an event rule sits in `scripts/lib/`. Components have `events/`, `hooks/<type>/` with a `hooks/matchers.json`, `scripts/{main,internal,lib}` and a `SKILL.md`.
- The current trees: `new-rewrite/framework/core/main-thread/` and `new-rewrite/domains/software-development/core/main-thread/`.

My proposal so far, with the owner's corrections still open, is in `reports/build-agent-tree.md`.

## Questions

1. **The tree** that is most consistent with new-rewrite: where the agents' components go, what they are named, and where the job events go.
2. **Installation:** if agents' components sit outside `main-thread/`, what changes in the installer, and is the installed name the folder name or something path-based?
3. **The owner's `agents/common/`:** keep the folder name with a path-based installed name, or a unique folder name?
4. Anything in the hook-folder rule (hook-only scripts in the hook folder) that clashes with new-rewrite's main/internal split or the internals guard.

Please answer in `tree-fable.md` in this folder, as a full tree, send the full result to Dev Beta, and give the owner one or two lines.
