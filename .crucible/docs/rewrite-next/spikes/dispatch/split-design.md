# Probe: initialize the agent, then give it the job (design, for Fable)

2026-11-26. Owner's direction; concept only, no spec. Replaces the prompt swap, which collides with auto mode (`auto-results.md`). Rule kept from Fable: no hook rewrites a call.

## The split

A dispatch today mixes two things. They become two events:

1. **`agent.initialized`**: a cold agent's setup (agent type, plugins). Written once, when the agent starts. A hot agent gets none, so the log shows plainly which jobs ran on a fresh agent and which on a resumed one.
2. **`job.dispatched`**: the job (kind, report path, tree, context, spec, grills, task words). Every job, hot or cold.

## How each reaches the agent

- **Plugins (cold only):** a SubagentStart hook adds the plugin texts as the agent's context before its first step, the closest copy of how Claude Code loads frontmatter skills. The agent has no choice; nothing asks it to read a file.
- **The job (hot and cold, same text):** the door prints one short job message. Cold: it is the Agent call's prompt, sent as printed, with `isolation: "worktree"`. Hot: it is the SendMessage text. No hook changes either call.

The step before the call only checks the call is the door's and leaves the note for the tree hook; it rewrites nothing.

## Questions

1. Does SubagentStart `additionalContext` reach a background sub-agent's context on 2.1.332, in auto mode, headless and interactive? Byte-equal to the plugin texts (checked in the transcript by me, never by a hook)?
2. Can the start hook find which agent type and plugins to load (from the note or the assignment written at the tree hook, the agent id in its payload)?
3. Does isolation set by main itself still drive WorktreeCreate, with no rewrite?
4. Do the real Opus builder and tester, 3 + 3, in auto mode, follow plugins given this way and the job given as the prompt: accepted at first stop, trees clean, asks counted?
5. Hot: one SendMessage job to a finished agent: no `agent.initialized`, the job followed.

Also in the run, from Fable's auto-mode verdict: the time limit set once in the settings env (no rewrite of agent commands), and a refusal step for a job agent's `git push`, `gh`, `glab`.

## Not in this probe

The "silence meant no" reading, the partial rerun, the spec.
