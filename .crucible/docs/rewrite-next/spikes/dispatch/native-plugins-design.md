# Probe: native plugin loading (design, for Fable)

2026-11-26. Owner: "I am trying to replace what CC is doing natively with complex shell". Goal: 3 job agents, plugins chosen per job, loaded by Claude Code itself, no start-hook parts. Quick spikes, stand-ins (haiku sub-agents, Opus main), headless, auto mode, sandbox under /Users/Shared. Concept facts only; no spec.

Plugins in the probe are two stand-in skills with marker lines, one ~15 KB (above the 10,000-char start-hook cap).

## Route 1: agent file written at dispatch time

The door writes `.claude/agents/<job-agent>.md` (one of the 3 bodies, frontmatter `skills: [<plugins>]`), main starts it.

1. Written mid-session (main writes it via Bash, then calls Agent with that type in the same session): accepted? Control: file present at session start.
2. Both skills' full text in the sub-agent's context before its first step (markers reported by the agent, and checked by me in the sub-agent transcript, byte-equal)?
3. Where the plugin skills must live for `skills:` to resolve (project `.claude/skills`), and what main then sees of them in its own skill list (cost and noise for main).
4. A second job agent file written later in the same session (a different plugin set): also accepted, the first unchanged?

## Route 2: the agent loads its own plugins

One fixed agent file with the Skill tool. The job message names the plugins.

1. Told "load skills A and B first": does it, both full texts in its context?
2. Gate: a PreToolUse hook, for a sub-agent only, refuses any tool but Skill until every named skill has loaded (seen at PostToolUse Skill). Does the PreToolUse payload carry the agent id, and with a job message that does not mention loading, does the refusal alone get both skills loaded?

## Pass

Route 1: steps 1, 2, 4 yes. Route 2: steps 1, 2 yes. Record what main's context holds in each.

## Not in this probe

Real builder/tester, trees, events, the spec.
