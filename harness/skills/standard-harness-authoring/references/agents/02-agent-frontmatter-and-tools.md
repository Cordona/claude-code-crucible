# agent-02 · Frontmatter and tools (ATOOL)

Purpose: the file loads, every field means what the author thinks, and the agent holds only the tools its role needs, with each restriction actually enforced.

**Applies when:** every agent file. ATOOL-19–ATOOL-21 are N/A for an orchestrator-only agent. The description is judged in agent-04.
**MUST lint:** LNT-48, LNT-50, LNT-59, LNT-61, LNT-66.
**Terms.** See `README.md` (verifier, orchestrator-only agent). **Write or execute tool:** Write, Edit, NotebookEdit, Bash, Agent, or an MCP tool that changes something.

**Levels.** Each item takes the level of the heading above it.

## Frontmatter

### MUST

- **ATOOL-01** · Are `name` and `description` present and non-empty? A file with no description, a bad name or broken YAML is skipped silently. · Check: lint LNT-59. · Fix: add the field.
- **ATOOL-02** · Is every frontmatter field one Claude Code knows, spelled in exact camelCase? Unknown fields are ignored without an error. · Check: lint LNT-59. · Fix: correct the spelling or remove the field.
- **ATOOL-03** · Is the agent's `name` valid and unique across the agents tree? · Check: lint LNT-48 and LNT-59. · Fix: rename the field or the file.
- **ATOOL-04** · Does each enumerated field hold an allowed value? · Check: lint LNT-59 (it holds the value lists). · Fix: use an allowed value.
- **ATOOL-05** · If the agent ships in a plugin (its file sits under a plugin's `agents/` dir, beside `.claude-plugin/plugin.json`), does it rely on no field plugins ignore: `hooks`, `mcpServers`, `permissionMode`, `initialPrompt`? · Check: read the frontmatter and its location. · Fix: move hooks to `hooks/hooks.json` and servers to `.mcp.json`; drop the rest.

## Tools

### MUST

- **ATOOL-06** · Does the agent set `tools`? Without it, the agent inherits every tool, MCP tools included. · Check: lint LNT-66. · Fix: list the tools its steps use.
- **ATOOL-07** · Is every write or execute tool in `tools` used by a step the body describes? · Check: for each one, find the step that needs it. · Fix: drop the tool.
- **ATOOL-09** · Does at least one listed tool resolve? If none does, the launch fails. · Check: compare `tools` with the subagent docs' tool list. · Fix: correct the names.
- **ATOOL-10** · Does a reviewer or arbiter hold none of Write, Edit, NotebookEdit and Bash, and does any other verifier hold no Write, Edit or NotebookEdit? · Check: lint LNT-50 for files in its scope; by hand for other verifiers. · Fix: drop the tools; return findings for the caller to write.
- **ATOOL-11** · Is `Bash` granted bare? `Bash(pattern)` in `tools` restricts no command. · Check: grep `tools` for `Bash(`. · Fix: write `Bash`; restrict commands with a permission deny rule, or with a PreToolUse hook only when the restriction depends on argument content a deny pattern can't match.
- **ATOOL-12** · When the agent holds Bash but must not write, does the body say read-only is a rule it follows, not a wall that will stop it, and name the commands it may run? · Check: read the body; N/A without Bash or for an agent that writes. · Fix: add "Read-only is a rule you follow here, not a permission that will block you; run only <commands>".
- **ATOOL-13** · Is `Agent` absent unless a step spawns subagents? In a subagent's `tools`, `Agent(type)` restricts nothing: it allows every type. · Check: read `tools` and the steps. · Fix: drop `Agent`; if spawning is needed, write it bare and name the allowed types in the body as a rule.
- **ATOOL-14** · Is every `disallowedTools` entry meant to remove the whole tool? An entry with a specifier (`Bash(git push *)`) removes all of Bash. · Check: read `disallowedTools`. · Fix: remove the specifier entry; block one command with a permission deny rule.
- **ATOOL-15** · Does a writing agent's claimed write scope have an enforcer, or does its body say plainly that the scope is unenforced? The default enforcer is a permission deny rule; use `isolation: worktree` when the work fits a fresh branch from the default branch (ATOOL-16), and a PreToolUse hook (not available to plugin agents) only when a deny pattern can't express the scope. · Check: read `hooks`, `isolation`, the permission deny rules in settings, and the body. · Fix: add a deny rule, or the other enforcer under its condition above, or the line "This scope is a rule, not enforced by any tool".
- **ATOOL-17** · Does the agent not rely on `permissionMode`, leaving it at `default`? It is ignored when the main session runs in bypassPermissions, acceptEdits or auto; `bypassPermissions` is never honoured from frontmatter; plugin agents ignore the field. · Check: read the value, if set, and any body text that depends on it. · Fix: leave `permissionMode` unset (or `default`); use `tools`, deny rules or a hook.
- **ATOOL-18** · Is `memory` unset on an agent that must not write? `memory` adds Read, Write and Edit. · Check: read `memory` against the role. · Fix: remove `memory`.
- **ATOOL-19** · Does the agent avoid every tool stripped from subagents: AskUserQuestion, EnterPlanMode, ExitPlanMode, Workflow, ScheduleWakeup, WaitForMcpServers, EndConversation? · Check: lint LNT-61; read `tools` and the steps. · Fix: drop the tool; return what the caller should do instead.
- **ATOOL-20** · Does the body never tell the agent to ask the user or wait for an answer? A subagent can't reach the user. · Check: lint LNT-61. · Fix: return the question in the output for the caller to ask.
- **ATOOL-21** · If the agent may run in the background (`background: true`, or a session where spawned agents run in the background), is every tool its process needs in the background set? That set is Read, Grep, Glob, LSP, Bash, PowerShell, Edit, Write, NotebookEdit, WebFetch, WebSearch, TodoWrite, Skill, ToolSearch, EnterWorktree, ExitWorktree, Monitor, TaskStop, SendMessage, Artifact, SubagentHandback and MCP tools. · Check: compare the steps' tools with the set. · Fix: drop the step's dependence on that tool, or require foreground dispatch in the flow.

### SHOULD

- **ATOOL-08** · Is every other listed tool used, and is each a current tool name (no leftovers like `LS` or `NotebookRead`)? · Check: compare `tools` with the steps and with the subagent docs' tool list. · Fix: drop the unused or stale name.
- **ATOOL-16** · When `isolation: worktree` is set, does the body account for the worktree branching from the default branch, not from the caller's HEAD? · Check: read the body; N/A without `isolation`. · Fix: state which branch the work needs, or use another enforcer.

## Model, effort, turns

### MUST

- **ATOOL-22** · Does the agent pin `model` to the house model's full model ID (the frontmatter-fields Versions table), never `inherit` or an alias? · Check: read the value; every agent pins model and effort explicitly so each can be changed per agent. · Fix: set `model` to the house model ID from that table; a different model needs an owner waiver.
- **ATOOL-23** · Does the agent pin `effort` explicitly, `medium` unless the owner decided otherwise? · Check: read the value; a level other than `medium` passes only with an owner waiver citing an EVAL-09 delta. · Fix: set `effort: medium`, or get the owner's waiver.

### SHOULD

- **ATOOL-24** · Is `maxTurns` sized to the role as a safety cap, tightest for an agent that reads beyond the files handed to it, traces effects, or loops? · Check: presence is LNT-66; judge the value against the process; whether the caller treats capped, partial output as unfinished is judged in 06. · Fix: set `maxTurns` sized to the role.
