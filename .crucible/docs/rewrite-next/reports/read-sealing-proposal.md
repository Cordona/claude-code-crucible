# Sealing framework scripts from reading, for main and for agents

By Dev Beta, from the owner's points (2026-11-25), for Fable's review.

## The owner's points

1. All hooks in all components live in `hooks/`, in one folder per hook name, each holding its scripts. Since the rework, that's `hooks/<event>/<wrapper>.sh` plus `steps/`.
2. Main is constrained by script from reading hook and internal scripts, to protect its context. Main may read only scripts that are neither hooks nor internals.
3. The same applies to subagents: no hooks, no internals, no main-only scripts.
4. **A consistent structure, kept the same when deployed, makes the sealing rules simple.**
5. To think about: scripts main can read that agents may also need to run, for example committing, or Jira, GitHub and GitLab issue scripts.

## Today

- `deny-internals-read.sh`, a step of the crucible-events guard, refuses main any Read, Grep or Glob path, or path in a Bash command, under any installed component's `scripts/internal/`, `scripts/lib/`, `hooks/` or `events/`. `scripts/main/` and `SKILL.md` stay readable.
- It **stands aside for subagents**, and for a session inside the framework's own repo, which is us developing it.
- The installed layout is flat: one folder per component under the skills folder, so one path pattern covers every component.

## Proposal

**The folder contract, the same in source and installed, per component:**

| Folder | Who may read it | Who may run it |
|---|---|---|
| `SKILL.md`, `references/` | main; an agent only for its own frontmatter skills | n/a |
| `scripts/main/` | main | main |
| `scripts/agent/` (new, only where needed) | main and agents | agents (and main) |
| `scripts/internal/`, `scripts/lib/` | nobody | the component's own scripts |
| `hooks/` (`<event>/`, `steps/`) | nobody | Claude Code |
| `events/` (rules), `submissions/` | nobody | the component's own scripts |

**The guard,** one rule for both main and subagents:
- **main** may read `SKILL.md`, `references/`, `scripts/main/` and `scripts/agent/`;
- **a subagent** may read `scripts/agent/` and the `SKILL.md` of the skills its own frontmatter loads;
- everything else in the framework is refused to both;
- the framework's own repo stays exempt, as today.

**Agents running scripts (point 5).** A script an agent must run goes in `scripts/agent/`, named by its job. Each one is decided on its own:
- **Committing:** agents never commit; the stop hook does, so no agent script.
- **Reading a tracker** (a Jira, GitHub or GitLab issue a task links to): a read-only script, for example today's `read-link.sh` in the `read-trackers` plugin, goes in `scripts/agent/`.
- **Writing to a tracker** (comments, issues): stays main's. It needs the human's consent, which an agent can't verify.

Allowing an agent to run a script is a Bash allow rule for that script's installed path, which the installer can write, since the path is fixed by the contract.

**What enforces it:** the existing guard step, widened (no subagent exception; the new readable set), plus install-check refusing a component whose folders break the contract. A script outside these folders is refused at install.

## Asked of Fable

1. Is the folder contract right, and is `scripts/agent/` the right home for agent-runnable scripts?
2. One guard for main and subagents, or a separate step per audience?
3. Should install-check enforce the contract, refusing a stray folder?
4. Point 5: any script beyond tracker reads that agents must run?
